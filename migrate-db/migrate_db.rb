#!/usr/bin/env ruby
# frozen_string_literal: true

# Clona/actualiza todas las tablas de un schema de PostgreSQL (prod o QA)
# hacia una base local. La primera ejecucion crea las tablas y copia los datos;
# las siguientes solo sincronizan cambios.
#
# Uso:
#   ./migrate_db.rb [opciones]
#
# Opciones:
#   --env-file PATH          Archivo .env (default: ../.env)
#   --source-schema NAME     Schema origen (default: SCHEMA del .env)
#   --dest-schema NAME       Schema destino (default: igual al origen)
#   --only a,b,c             Sincronizar solo estas tablas
#   --exclude a,b,c          Excluir estas tablas
#   --full                   Recargar por completo las tablas seleccionadas
#   --prune                  Borrar en local las filas que ya no existen en origen
#   --overlap-seconds N      Margen de solapamiento para cambios (default: 300)
#   --no-analyze             No ejecutar ANALYZE despues de cada tabla
#   --verbose                Mostrar mas detalle
#   --help                   Mostrar esta ayuda
#
# El .env debe contener:
#   CONNECTION_STRING, DATABASE, USER, PASSWORD, SCHEMA   (origen)
#   CONNECTION_STRING_LOCAL, POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD (destino)
#
# Requiere la gema pg:  gem install pg

require "pg"
require "optparse"
require "time"

class MigrateDB
  STATE_TABLE = "public._migrate_db_state"
  UPDATED_AT_CANDIDATES = %w[updated_at modified_at last_updated fecha_actualizacion].freeze
  FULL_ACTIONS = ["clonada", "recargada", "recargada sin clave", "vaciada"].freeze

  def initialize(argv)
    @options = {
      env_file: ENV["ENV_FILE"] || File.expand_path("../.env", __dir__),
      overlap_seconds: (ENV["SYNC_OVERLAP_SECONDS"] || 300).to_i,
      full: false,
      prune: false,
      analyze: true,
      verbose: false
    }
    parse_options!(argv)

    @env = load_env(@options[:env_file])
    @source_schema = @options[:source_schema] || env_value("SCHEMA")
    @dest_schema = @options[:dest_schema] || @source_schema
    @source_data_timezone = ENV["SOURCE_DATA_TIMEZONE"] || ENV["TZ"] || "America/Mexico_City"
    @only = @options[:only]
    @exclude = @options[:exclude] || []
    @stage_counter = 0
    @stats = Hash.new(0)
    @errors = []
    @null_check_cache = {}
    @source_column_cache = {}
    @source_unique_cache = {}
    @source_pk_cache = {}
  end

  def run
    connect!
    prepare_destination!
    create_enums!
    create_sequences!

    tables = source_tables
    tables = filter_tables(tables)
    print_header(tables)

    tables.each_with_index do |info, index|
      sync_table(info, index + 1, tables.size)
    end

    create_foreign_keys!(tables)
    apply_sequence_ownership!
    update_sequence_values!
    print_summary

    @errors.empty? ? 0 : 1
  rescue StandardError => e
    warn "ERROR: #{e.message}"
    warn e.backtrace.first(8).join("\n") if @options[:verbose]
    1
  ensure
    disconnect!
  end

  private

  def parse_options!(argv)
    parser = OptionParser.new do |opts|
      opts.banner = "Uso: #{File.basename($0)} [opciones]"
      opts.on("--env-file PATH", "Archivo .env") { |v| @options[:env_file] = File.expand_path(v) }
      opts.on("--source-schema NAME", "Schema origen") { |v| @options[:source_schema] = v }
      opts.on("--dest-schema NAME", "Schema destino") { |v| @options[:dest_schema] = v }
      opts.on("--only LISTA", "Tablas separadas por coma") { |v| @options[:only] = split_list(v) }
      opts.on("--exclude LISTA", "Tablas a excluir separadas por coma") { |v| @options[:exclude] = split_list(v) }
      opts.on("--full", "Recargar por completo") { @options[:full] = true }
      opts.on("--prune", "Borrar filas que ya no existen en origen") { @options[:prune] = true }
      opts.on("--schema-only", "Crear estructura sin copiar datos") { @options[:schema_only] = true }
      opts.on("--overlap-seconds N", Integer, "Solapamiento en segundos") { |v| @options[:overlap_seconds] = v }
      opts.on("--source-data-timezone NAME", "Zona horaria usada en los datos de origen") { |v| @options[:source_data_timezone] = v }
      opts.on("--no-analyze", "No ejecutar ANALYZE") { @options[:analyze] = false }
      opts.on("--verbose", "Mostrar detalle") { @options[:verbose] = true }
      opts.on("-h", "--help", "Mostrar ayuda") do
        puts opts
        exit 0
      end
    end
    parser.parse!(argv)
    @source_data_timezone = @options[:source_data_timezone] if @options[:source_data_timezone]
  end

  def split_list(value)
    value.split(",").map(&:strip).reject(&:empty?)
  end

  def load_env(path)
    raise "No existe el archivo .env: #{path}" unless File.file?(path)

    env = {}
    File.foreach(path) do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      key, raw = line.split("=", 2)
      next unless raw

      key = key.strip
      value = raw.strip
      if value.length >= 2 && value.start_with?('"') && value.end_with?('"')
        value = value[1...-1].gsub('\\"', '"')
      elsif value.length >= 2 && value.start_with?("'") && value.end_with?("'")
        value = value[1...-1].gsub("\\'", "'")
      else
        value = value.sub(/\s+#.*\z/, "")
      end
      env[key] = value
    end
    env
  end

  def env_value(key)
    value = @env[key]
    raise "Falta la variable #{key} en #{@options[:env_file]}" if value.nil? || value.empty?
    value
  end

  def parse_connection(value)
    if value =~ %r{\Apostgres(ql)?://}i
      { url: value }
    else
      host_port = value.include?("@") ? value.split("@", 2).last : value
      host, port = host_port.split(":", 2)
      raise "Connection string invalida: #{value}" if host.nil? || host.empty?
      { host: host, port: (port || 5432).to_i }
    end
  end

  def connect!
    src = parse_connection(env_value("CONNECTION_STRING"))
    @source = if src[:url]
                PG.connect(src[:url])
              else
                PG.connect(
                  host: src[:host],
                  port: src[:port],
                  dbname: env_value("DATABASE"),
                  user: env_value("USER"),
                  password: env_value("PASSWORD"),
                  connect_timeout: 15,
                  application_name: "migrate_db"
                )
              end

    dst = parse_connection(env_value("CONNECTION_STRING_LOCAL"))
    @dest = if dst[:url]
              PG.connect(dst[:url])
            else
              PG.connect(
                host: dst[:host],
                port: dst[:port],
                dbname: env_value("POSTGRES_DB"),
                user: env_value("POSTGRES_USER"),
                password: env_value("POSTGRES_PASSWORD"),
                connect_timeout: 15,
                application_name: "migrate_db"
              )
            end

    [@source, @dest].each do |conn|
      conn.exec("SET client_encoding = 'UTF8'")
      conn.exec("SET TimeZone = 'UTC'")
      conn.exec("SET statement_timeout = 0")
      conn.exec("SET lock_timeout = 0")
    end
    @source.exec("SET application_name = 'migrate_db'")
    @dest.exec("SET synchronous_commit = 'off'")
    begin
      @dest.exec("SET session_replication_role = 'replica'")
      @replication_role = true
    rescue PG::Error => e
      @replication_role = false
      warn "AVISO: no se pudieron desactivar triggers/FKs en local: #{e.message}"
    end
  end

  def disconnect!
    @source&.close
    @dest&.close
  rescue StandardError
    nil
  end

  def prepare_destination!
    @dest.exec("CREATE SCHEMA IF NOT EXISTS #{quote_ident(@dest_schema)}")
    @dest.exec("SET search_path TO #{quote_ident(@dest_schema)}, public")
    @dest.exec(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{STATE_TABLE} (
        source_schema text NOT NULL,
        dest_schema   text NOT NULL,
        table_name    text NOT NULL,
        key_columns   text,
        last_sync_at  timestamptz,
        last_full_at  timestamptz,
        last_status   text,
        last_error    text,
        updated_at    timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (source_schema, dest_schema, table_name)
      )
    SQL

    has_exclusion = @source.exec_params(<<~SQL, [@source_schema]).ntuples.positive?
      SELECT 1
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND k.contype = 'x'
      LIMIT 1
    SQL
    if has_exclusion
      begin
        @dest.exec("CREATE EXTENSION IF NOT EXISTS btree_gist")
      rescue PG::Error => e
        warn "AVISO: no se pudo crear la extension btree_gist: #{e.message}"
      end
    end
  end

  def source_tables
    @source.exec_params(<<~SQL, [@source_schema]).map do |row|
      SELECT c.relname AS name, c.reltuples::bigint AS estimated_rows
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relkind = 'r'
      ORDER BY c.relname
    SQL
      { name: row["name"], estimated_rows: row["estimated_rows"].to_i }
    end
  end

  def filter_tables(tables)
    names = tables.map { |t| t[:name] }
    if @only
      missing = @only - names
      warn "AVISO: tablas no encontradas en origen: #{missing.join(', ')}" unless missing.empty?
      tables = tables.select { |t| @only.include?(t[:name]) }
    end
    unless @exclude.empty?
      tables = tables.reject { |t| @exclude.include?(t[:name]) }
    end
    raise "No hay tablas para sincronizar" if tables.empty?
    tables
  end

  def print_header(tables)
    src = parse_connection(env_value("CONNECTION_STRING"))
    dst = parse_connection(env_value("CONNECTION_STRING_LOCAL"))
    src_desc = src[:url] ? safe_url(src[:url]) : "#{src[:host]}:#{src[:port]}/#{env_value('DATABASE')}"
    dst_desc = dst[:url] ? safe_url(dst[:url]) : "#{dst[:host]}:#{dst[:port]}/#{env_value('POSTGRES_DB')}"

    puts "Migracion de base de datos"
    puts "  Origen  : #{src_desc} (schema #{@source_schema}, usuario #{env_value('USER')})"
    puts "  Destino : #{dst_desc} (schema #{@dest_schema}, usuario #{env_value('POSTGRES_USER')})"
    puts "  Tablas  : #{tables.size}"
    mode = if @options[:schema_only]
             "solo estructura"
           elsif @options[:full]
             "recarga completa"
           else
             "incremental"
           end
    puts "  Modo    : #{mode}"
    puts
  end

  def safe_url(url)
    url.gsub(%r{(://[^:/@]+:)[^@]+@}, '\1<oculto>@')
  end

  def sync_table(info, index, total)
    table = info[:name]
    started = Time.now
    print format("[%d/%d] %-45s ", index, total, table)
    $stdout.flush

    sync_time = source_now
    state = fetch_state(table)
    source_cols = source_columns(table)
    raise "la tabla no tiene columnas" if source_cols.empty?

    local_existed = local_table?(table)
    needs_full = false

    if local_existed
      needs_full = add_missing_columns!(table, source_cols)
    else
      create_table!(table, source_cols)
    end

    needs_full ||= state[:last_status] == "error"
    action = nil
    full_state = false

    if @options[:schema_only]
      ensure_constraints!(table)
      action = "estructura"
    else
      empty = local_table_empty?(table)
      desired_key = choose_source_key(table, state, source_cols)

      if empty && !needs_full
        @dest.transaction { full_copy!(table, source_cols) }
        ensure_constraints!(table)
        key = local_key(table, desired_key)
        action = "clonada"
        full_state = true
      elsif @options[:full] || needs_full
        truncate_and_copy!(table, source_cols)
        ensure_constraints!(table)
        key = local_key(table, desired_key)
        action = "recargada"
        full_state = true
      else
        ensure_constraints!(table)
        key = local_key(table, desired_key)

        if source_table_empty?(table)
          truncate_table!(table)
          action = "vaciada"
          full_state = true
        elsif key.nil?
          truncate_and_copy!(table, source_cols)
          action = "recargada sin clave"
          full_state = true
        elsif @options[:prune]
          merge_full!(table, source_cols, key, prune: true)
          action = "sincronizada (prune)"
        elsif (delta_cols = delta_columns(source_cols)).any? && state[:last_sync_at]
          merge_delta!(table, source_cols, key, delta_cols, state[:last_sync_at])
          action = "actualizada"
        else
          merge_full!(table, source_cols, key, prune: false)
          action = "sincronizada"
        end
      end
    end

    analyze_table!(table) if @options[:analyze]
    save_state!(table, key, sync_time, action, full_state) unless @options[:schema_only]
    @stats[action] += 1
    puts "#{action} (#{format_duration(Time.now - started)})"
  rescue StandardError => e
    @errors << [table, e.message]
    puts "ERROR: #{e.message}"
    save_error_state(table, e.message)
  end

  def source_now
    tz = @source.escape_literal(@source_data_timezone)
    @source.exec(<<~SQL).getvalue(0, 0)
      SELECT ((clock_timestamp() AT TIME ZONE #{tz}) AT TIME ZONE 'UTC')::text
    SQL
  end

  def fetch_state(table)
    row = @dest.exec_params(<<~SQL, [@source_schema, @dest_schema, table]).first
      SELECT key_columns, last_sync_at::text AS last_sync_at, last_status
      FROM #{STATE_TABLE}
      WHERE source_schema = $1 AND dest_schema = $2 AND table_name = $3
    SQL
    return { key_columns: nil, last_sync_at: nil, last_status: nil } unless row

    key_columns = row["key_columns"]&.split(",")&.map(&:strip)
    {
      key_columns: key_columns&.empty? ? nil : key_columns,
      last_sync_at: row["last_sync_at"],
      last_status: row["last_status"]
    }
  end

  def save_state!(table, key, sync_time, action, full_state)
    @dest.exec_params(<<~SQL, [
      INSERT INTO #{STATE_TABLE} AS st
        (source_schema, dest_schema, table_name, key_columns, last_sync_at,
         last_full_at, last_status, last_error, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, 'ok', NULL, now())
      ON CONFLICT (source_schema, dest_schema, table_name) DO UPDATE SET
        key_columns  = EXCLUDED.key_columns,
        last_sync_at = EXCLUDED.last_sync_at,
        last_full_at = COALESCE(EXCLUDED.last_full_at, st.last_full_at),
        last_status  = 'ok',
        last_error   = NULL,
        updated_at   = now()
    SQL
      @source_schema,
      @dest_schema,
      table,
      key&.join(","),
      sync_time,
      full_state ? sync_time : nil
    ])
  end

  def save_error_state(table, message)
    @dest.exec_params(<<~SQL, [@source_schema, @dest_schema, table, message[0, 2000]])
      INSERT INTO #{STATE_TABLE} AS st
        (source_schema, dest_schema, table_name, last_status, last_error, updated_at)
      VALUES ($1, $2, $3, 'error', $4, now())
      ON CONFLICT (source_schema, dest_schema, table_name) DO UPDATE SET
        last_status = 'error',
        last_error  = EXCLUDED.last_error,
        updated_at  = now()
    SQL
  rescue StandardError
    nil
  end

  def source_columns(table)
    @source_column_cache[table] ||= @source.exec_params(<<~SQL, [@source_schema, table]).map do |row|
      SELECT a.attname AS name,
             format_type(a.atttypid, a.atttypmod) AS type,
             a.attnotnull AS notnull,
             a.attidentity AS identity,
             a.attgenerated AS generated,
             pg_get_expr(d.adbin, d.adrelid) AS default_expr,
             CASE
               WHEN a.attcollation <> t.typcollation
                 THEN quote_ident(cn.nspname) || '.' || quote_ident(co.collname)
             END AS collation
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_type t ON t.oid = a.atttypid
      LEFT JOIN pg_collation co ON co.oid = a.attcollation
      LEFT JOIN pg_namespace cn ON cn.oid = co.collnamespace
      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
      ORDER BY a.attnum
    SQL
      {
        name: row["name"],
        type: row["type"],
        notnull: row["notnull"] == "t",
        identity: row["identity"],
        generated: row["generated"],
        default_expr: row["default_expr"],
        collation: row["collation"]
      }
    end
  end

  def local_columns(table)
    @dest.exec_params(<<~SQL, [@dest_schema, table]).map do |row|
      SELECT a.attname AS name, format_type(a.atttypid, a.atttypmod) AS type
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
      ORDER BY a.attnum
    SQL
      { name: row["name"], type: row["type"] }
    end
  end

  def local_table?(table)
    @dest.exec_params(<<~SQL, [@dest_schema, table]).ntuples.positive?
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'p')
    SQL
  end

  def local_table_empty?(table)
    @dest.exec("SELECT NOT EXISTS (SELECT 1 FROM #{dest_table(table)})").getvalue(0, 0) == "t"
  end

  def source_table_empty?(table)
    @source.exec("SELECT NOT EXISTS (SELECT 1 FROM #{src_table(table)})").getvalue(0, 0) == "t"
  end

  def create_table!(table, columns)
    relaxed = columns.map(&:dup)
    omitted = []
    attempts = 0

    loop do
      begin
        @dest.exec(create_table_sql(table, relaxed))
        break
      rescue PG::Error => e
        raise unless missing_dependency_error?(e) && !local_table?(table)

        attempts += 1
        raise if attempts > 10

        token = missing_dependency_token(e.message)
        candidates = relaxed.select do |column|
          column[:default_expr] && column[:generated] != "s" &&
            (token.nil? || column[:default_expr].include?(token))
        end
        candidates = relaxed.select { |column| column[:default_expr] && column[:generated] != "s" } if candidates.empty?
        raise if candidates.empty?

        candidates.each do |column|
          omitted << column[:name]
          column[:default_expr] = nil
        end
      end
    end

    return if omitted.empty?

    warn "\n  AVISO: defaults omitidos en #{table}: #{omitted.uniq.join(', ')}"
  end

  def create_table_sql(table, columns)
    definitions = columns.map { |column| column_definition(column) }
    <<~SQL
      CREATE TABLE IF NOT EXISTS #{dest_table(table)} (
        #{definitions.join(",\n  ")}
      )
    SQL
  end

  def missing_dependency_error?(error)
    error.message.match?(/does not exist|no existe|undefined function|undefined object|schema .* not found|invalid schema/i)
  end

  def missing_dependency_token(message)
    if (match = message.match(/function\s+([a-zA-Z0-9_."]+)\s*\(/i))
      match[1].delete('"')
    elsif (match = message.match(/schema\s+"?([a-zA-Z0-9_]+)"?\s+does not exist/i))
      match[1]
    elsif (match = message.match(/type\s+"?([a-zA-Z0-9_."]+)"?\s+does not exist/i))
      match[1].delete('"')
    end
  end

  def add_missing_columns!(table, source_cols)
    existing = local_columns(table).to_h { |column| [column[:name], column[:type]] }
    missing = source_cols.reject { |column| existing.key?(column[:name]) }
    return false if missing.empty?

    was_empty = local_table_empty?(table)
    missing.each do |column|
      definition = column_definition(column)
      begin
        @dest.exec("ALTER TABLE #{dest_table(table)} ADD COLUMN #{definition}")
        puts "\n  + columna agregada: #{column[:name]}"
      rescue PG::Error => e
        if missing_dependency_error?(e) && column[:default_expr]
          relaxed = column.merge(default_expr: nil, notnull: false)
          @dest.exec("ALTER TABLE #{dest_table(table)} ADD COLUMN #{column_definition(relaxed)}")
          puts "\n  + columna agregada sin default: #{column[:name]} (#{e.message})"
        elsif column[:notnull] && column[:default_expr].nil?
          relaxed = column.merge(notnull: false)
          @dest.exec("ALTER TABLE #{dest_table(table)} ADD COLUMN #{column_definition(relaxed)}")
          puts "\n  + columna agregada sin NOT NULL: #{column[:name]} (#{e.message})"
        else
          raise
        end
      end
    end

    source_cols.each do |column|
      local_type = existing[column[:name]]
      next unless local_type
      next if normalize_type(local_type) == normalize_type(column[:type])

      warn "\n  AVISO: tipo distinto en #{table}.#{column[:name]} (local: #{local_type}, origen: #{column[:type]})"
    end

    !was_empty
  end

  def column_definition(column)
    parts = [quote_ident(column[:name]), rewrite_sql(column[:type])]
    parts << "COLLATE #{column[:collation]}" if column[:collation]

    if column[:generated] == "s"
      parts << "GENERATED ALWAYS AS (#{rewrite_sql(column[:default_expr])}) STORED"
    elsif column[:identity] == "a"
      parts << "GENERATED ALWAYS AS IDENTITY"
    elsif column[:identity] == "d"
      parts << "GENERATED BY DEFAULT AS IDENTITY"
    elsif column[:default_expr]
      parts << "DEFAULT #{rewrite_sql(column[:default_expr])}"
    end

    parts << "NOT NULL" if column[:notnull]
    parts.join(" ")
  end

  def normalize_type(type)
    type.to_s.downcase.gsub(/\s+/, " ").strip
  end

  def rewrite_sql(sql)
    return sql if sql.nil? || @source_schema == @dest_schema

    sql
      .gsub(/#{Regexp.escape(@source_schema)}\./, "#{@dest_schema}.")
      .gsub("'#{@source_schema}.", "'#{@dest_schema}.")
  end

  def non_generated_columns(columns)
    columns.reject { |column| column[:generated] == "s" }
  end

  def column_list(columns)
    columns.map { |column| quote_ident(column[:name]) }.join(", ")
  end

  def full_copy!(table, columns)
    cols = non_generated_columns(columns)
    select_sql = "SELECT #{column_list(cols)} FROM #{src_table(table)}"
    dest_copy_sql = "COPY #{dest_table(table)} (#{column_list(cols)}) FROM STDIN"
    stream_copy(select_sql, dest_copy_sql)
  end

  def truncate_table!(table)
    @dest.exec("TRUNCATE TABLE ONLY #{dest_table(table)}")
  end

  def truncate_and_copy!(table, columns)
    @dest.transaction do
      truncate_table!(table)
      full_copy!(table, columns)
    end
  end


  def merge_delta!(table, columns, key, delta_cols, last_sync_at)
    overlap = @options[:overlap_seconds].to_i
    tz = @source.escape_literal(@source_data_timezone)
    current_data_time = "((clock_timestamp() AT TIME ZONE #{tz}) AT TIME ZONE 'UTC')"
    cutoff = "LEAST(#{@source.escape_literal(last_sync_at)}::timestamptz, #{current_data_time}) - interval '#{overlap} seconds'"
    conditions = delta_cols.map { |column| "#{quote_ident(column)} >= #{cutoff}" }
    merge_rows!(table, columns, key, where_sql: conditions.join(" OR "), full_scan: false, prune: false)
  end

  def merge_full!(table, columns, key, prune:)
    merge_rows!(table, columns, key, where_sql: nil, full_scan: true, prune: prune)
  end

  def merge_rows!(table, columns, key, where_sql:, full_scan:, prune:)
    cols = non_generated_columns(columns)
    key_set = key.to_set
    update_cols = cols.reject { |column| key_set.include?(column[:name]) }
    select_sql = "SELECT #{column_list(cols)} FROM #{src_table(table)}"
    select_sql += " WHERE #{where_sql}" if where_sql

    identity_always = cols.any? { |column| column[:identity] == "a" }
    stage = "migrate_stage_#{@stage_counter += 1}"

    @dest.transaction do
      @dest.exec(<<~SQL)
        CREATE TEMP TABLE #{quote_ident(stage)}
        ON COMMIT DROP
        AS SELECT #{column_list(cols)} FROM #{dest_table(table)} WITH NO DATA
      SQL

      stream_copy(select_sql, "COPY #{quote_ident(stage)} (#{column_list(cols)}) FROM STDIN")

      insert_sql = +"INSERT INTO #{dest_table(table)} AS d (#{column_list(cols)})"
      insert_sql << " OVERRIDING SYSTEM VALUE" if identity_always
      insert_sql << " SELECT #{column_list(cols)} FROM #{quote_ident(stage)}"
      insert_sql << " ON CONFLICT (#{key.map { |column| quote_ident(column) }.join(', ')})"

      if update_cols.empty?
        insert_sql << " DO NOTHING"
      else
        assignments = update_cols.map do |column|
          "#{quote_ident(column[:name])} = EXCLUDED.#{quote_ident(column[:name])}"
        end
        compare_left = cols.map { |column| "d.#{quote_ident(column[:name])}" }.join(", ")
        compare_right = cols.map { |column| "EXCLUDED.#{quote_ident(column[:name])}" }.join(", ")
        insert_sql << " DO UPDATE SET #{assignments.join(', ')}"
        insert_sql << " WHERE (#{compare_left}) IS DISTINCT FROM (#{compare_right})"
      end

      @dest.exec(insert_sql)

      if prune && full_scan
        join = key.map do |column|
          "s.#{quote_ident(column)} = d.#{quote_ident(column)}"
        end.join(" AND ")
        @dest.exec(<<~SQL)
          DELETE FROM #{dest_table(table)} AS d
          WHERE NOT EXISTS (
            SELECT 1 FROM #{quote_ident(stage)} AS s WHERE #{join}
          )
        SQL
      end
    end
  end

  def stream_copy(source_select, dest_copy)
    @dest.copy_data(dest_copy) do
      @source.copy_data("COPY (#{source_select}) TO STDOUT") do
        while (chunk = @source.get_copy_data)
          @dest.put_copy_data(chunk)
        end
      end
    end
  end

  def source_primary_key(table)
    @source_pk_cache[table] ||= begin
      columns = @source.exec_params(<<~SQL, [@source_schema, table]).map { |row| row["attname"] }
        SELECT a.attname
        FROM pg_constraint k
        JOIN pg_class c ON c.oid = k.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN LATERAL unnest(k.conkey) WITH ORDINALITY u(attnum, ord) ON TRUE
        JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.attnum
        WHERE n.nspname = $1 AND c.relname = $2
          AND k.contype = 'p' AND NOT k.condeferrable
        ORDER BY u.ord
      SQL
      columns.empty? ? nil : columns
    end
  end

  def source_unique_keys(table)
    @source_unique_cache[table] ||= begin
      rows = @source.exec_params(<<~SQL, [@source_schema, table])
        SELECT i.indexrelid::text AS index_oid,
               i.indnullsnotdistinct AS nulls_not_distinct,
               a.attname,
               a.attnotnull,
               u.ord
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN LATERAL unnest(i.indkey) WITH ORDINALITY u(attnum, ord) ON TRUE
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = u.attnum
        WHERE n.nspname = $1 AND c.relname = $2
          AND i.indisunique AND i.indisvalid AND i.indimmediate
          AND i.indpred IS NULL AND i.indexprs IS NULL
          AND u.ord <= i.indnkeyatts
        ORDER BY i.indexrelid, u.ord
      SQL

      grouped = rows.group_by { |row| row["index_oid"] }
      keys = grouped.map do |_oid, idx_rows|
        {
          columns: idx_rows.map { |row| row["attname"] },
          nullable: idx_rows.any? { |row| row["attnotnull"] != "t" },
          nulls_not_distinct: idx_rows.first["nulls_not_distinct"] == "t"
        }
      end
      keys.uniq { |key| key[:columns] }
          .reject { |key| key[:columns].empty? }
          .sort_by { |key| [key[:columns].length, key[:columns].join(",")] }
    end
  end

  def choose_source_key(table, state, columns)
    pk = source_primary_key(table)
    return pk if pk && !pk.empty?

    candidates = source_unique_keys(table)
    cached = state[:key_columns]
    if cached
      candidate = candidates.find { |item| item[:columns] == cached }
      return cached if candidate && (candidate[:nulls_not_distinct] || !candidate[:nullable] || key_has_no_nulls?(table, cached))
    end

    candidates.each do |candidate|
      cols = candidate[:columns]
      next if candidate[:nullable] && !candidate[:nulls_not_distinct] && !key_has_no_nulls?(table, cols)
      return cols
    end
    nil
  end

  def key_has_no_nulls?(table, columns)
    cache_key = [table, columns]
    return @null_check_cache[cache_key] if @null_check_cache.key?(cache_key)

    stats_cover = begin
      placeholders = columns.each_index.map { |index| "$#{index + 3}" }.join(", ")
      @source.exec_params(
        "SELECT 1 FROM pg_stats WHERE schemaname = $1 AND tablename = $2 AND attname IN (#{placeholders})",
        [@source_schema, table] + columns
      ).ntuples
    end
    if stats_cover == columns.length
      placeholders = columns.each_index.map { |index| "$#{index + 3}" }.join(", ")
      max_null_frac = @source.exec_params(
        "SELECT COALESCE(MAX(null_frac), 0) FROM pg_stats WHERE schemaname = $1 AND tablename = $2 AND attname IN (#{placeholders})",
        [@source_schema, table] + columns
      ).getvalue(0, 0)
      if max_null_frac.to_f.zero?
        @null_check_cache[cache_key] = true
        return true
      end
      @null_check_cache[cache_key] = false
      return false
    end

    condition = columns.map { |column| "#{quote_ident(column)} IS NULL" }.join(" OR ")
    exists = @source.exec("SELECT 1 FROM #{src_table(table)} WHERE #{condition} LIMIT 1").ntuples.positive?
    @null_check_cache[cache_key] = !exists
    !exists
  end

  def local_key(table, desired)
    return nil if desired.nil?

    local_unique_keys(table).any? { |columns| columns == desired } ? desired : nil
  end

  def local_unique_keys(table)
    rows = @dest.exec_params(<<~SQL, [@dest_schema, table])
      SELECT i.indexrelid::text AS index_oid, a.attname, u.ord
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN LATERAL unnest(i.indkey) WITH ORDINALITY u(attnum, ord) ON TRUE
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = u.attnum
      WHERE n.nspname = $1 AND c.relname = $2
        AND i.indisunique AND i.indisvalid AND i.indimmediate
        AND i.indpred IS NULL AND i.indexprs IS NULL
        AND u.ord <= i.indnkeyatts
      ORDER BY i.indexrelid, u.ord
    SQL
    rows.group_by { |row| row["index_oid"] }
        .values
        .map { |idx_rows| idx_rows.map { |row| row["attname"] } }
        .uniq
        .reject(&:empty?)
  end

  def delta_columns(columns)
    candidates = UPDATED_AT_CANDIDATES + ["created_at"]
    candidates.filter_map do |name|
      column = columns.find { |item| item[:name] == name }
      next unless column
      next unless column[:type].to_s.include?("timestamp")
      name
    end.uniq
  end

  def ensure_constraints!(table)
    source_constraints = @source.exec_params(<<~SQL, [@source_schema, table]).map do |row|
      SELECT k.conname, k.contype, pg_get_constraintdef(k.oid) AS definition
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relname = $2 AND k.contype IN ('p', 'u', 'c', 'x')
      ORDER BY k.contype, k.conname
    SQL
      { name: row["conname"], type: row["contype"], definition: row["definition"] }
    end.uniq { |item| [item[:type], normalize_definition(item[:definition])] }

    local_constraints = @dest.exec_params(<<~SQL, [@dest_schema, table])
      SELECT k.conname, k.contype, pg_get_constraintdef(k.oid) AS definition
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relname = $2
    SQL

    local_defs = local_constraints.map { |row| [row["contype"], normalize_definition(row["definition"])] }.to_set
    local_names = local_constraints.map { |row| row["conname"] }.to_set

    source_constraints.each do |constraint|
      normalized = normalize_definition(constraint[:definition])
      next if local_defs.include?([constraint[:type], normalized])

      name = available_name(constraint[:name], local_names)
      definition = rewrite_sql(normalize_definition(constraint[:definition]))
      definition += " NOT VALID" if constraint[:type] == "c"

      sql = "ALTER TABLE ONLY #{dest_table(table)} ADD CONSTRAINT #{quote_ident(name)} #{definition}"
      begin
        @dest.exec(sql)
      rescue PG::Error => e
        warn "\n  AVISO: no se pudo crear constraint #{constraint[:name]} en #{table}: #{e.message}"
        next
      end
      local_defs << [constraint[:type], normalized]
      local_names << name
    end

    create_missing_indexes!(table)
  end

  def normalize_definition(definition)
    definition.to_s.sub(/\s+NOT VALID\z/i, "").strip
  end

  def available_name(base, used)
    name = base[0, 63]
    return name unless used.include?(name)

    suffix = 1
    loop do
      candidate = "#{base[0, 55]}_#{suffix}"
      return candidate unless used.include?(candidate)
      suffix += 1
    end
  end

  def create_missing_indexes!(table)
    indexes = @source.exec_params(<<~SQL, [@source_schema, table]).map do |row|
      SELECT ic.relname AS index_name,
             i.indisunique AS unique,
             i.indkey::text AS indkey,
             i.indclass::text AS indclass,
             i.indoption::text AS indoption,
             i.indexprs::text AS indexprs,
             i.indpred::text AS indpred,
             pg_get_indexdef(i.indexrelid) AS definition
      FROM pg_index i
      JOIN pg_class tc ON tc.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = tc.relnamespace
      JOIN pg_class ic ON ic.oid = i.indexrelid
      WHERE n.nspname = $1 AND tc.relname = $2
        AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)
      ORDER BY ic.relname
    SQL
      {
        name: row["index_name"],
        unique: row["unique"],
        indkey: row["indkey"],
        indclass: row["indclass"],
        indoption: row["indoption"],
        indexprs: row["indexprs"],
        indpred: row["indpred"],
        definition: row["definition"]
      }
    end

    indexes = indexes.uniq do |index|
      [index[:unique], index[:indkey], index[:indclass], index[:indoption], index[:indexprs], index[:indpred]]
    end

    local_indexes = @dest.exec_params(<<~SQL, [@dest_schema]).map { |row| row["relname"] }.to_set
      SELECT c.relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relkind IN ('i', 'I')
    SQL

    indexes.each do |index|
      next if local_indexes.include?(index[:name])

      begin
        definition = rewrite_index_definition(index[:definition], table, index[:name])
        @dest.exec(definition)
        local_indexes << index[:name]
      rescue PG::Error => e
        warn "\n  AVISO: no se pudo crear indice #{index[:name]} en #{table}: #{e.message}"
      end
    end
  end

  def rewrite_index_definition(definition, table, index_name)
    match = definition.match(/\ACREATE (UNIQUE )?INDEX (.+?) ON (.+?) (USING .+)\z/m)
    raise "No se pudo interpretar el indice de #{table}: #{definition}" unless match

    prefix = match[1] ? "CREATE UNIQUE INDEX" : "CREATE INDEX"
    "#{prefix} #{quote_ident(index_name)} ON #{dest_table(table)} #{rewrite_sql(match[4])}"
  end

  def create_foreign_keys!(tables)
    selected = tables.map { |table| table[:name] }.to_set
    rows = @source.exec_params(<<~SQL, [@source_schema]).map do |row|
      SELECT c.relname AS table_name,
             k.conname,
             (SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY u.ord)
              FROM unnest(k.conkey) WITH ORDINALITY u(attnum, ord)
              JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.attnum) AS columns,
             n2.nspname AS ref_schema,
             c2.relname AS ref_table,
             (SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY u.ord)
              FROM unnest(k.confkey) WITH ORDINALITY u(attnum, ord)
              JOIN pg_attribute a ON a.attrelid = k.confrelid AND a.attnum = u.attnum) AS ref_columns,
             k.confupdtype, k.confdeltype, k.confmatchtype,
             k.condeferrable, k.condeferred
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_class c2 ON c2.oid = k.confrelid
      JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
      WHERE n.nspname = $1 AND k.contype = 'f'
      ORDER BY c.relname, k.conname
    SQL
      {
        table_name: row["table_name"],
        name: row["conname"],
        columns: row["columns"],
        ref_schema: row["ref_schema"],
        ref_table: row["ref_table"],
        ref_columns: row["ref_columns"],
        update_action: row["confupdtype"],
        delete_action: row["confdeltype"],
        match_type: row["confmatchtype"],
        deferrable: row["condeferrable"] == "t",
        deferred: row["condeferred"] == "t"
      }
    end

    skipped = 0
    rows.each do |fk|
      next unless selected.include?(fk[:table_name])
      unless local_table?(fk[:table_name]) && local_table?(fk[:ref_table])
        skipped += 1
        next
      end

      ref_schema = fk[:ref_schema] == @source_schema ? @dest_schema : fk[:ref_schema]
      definition = foreign_key_definition(fk, ref_schema)
      local_constraints = @dest.exec_params(<<~SQL, [@dest_schema, fk[:table_name]])
        SELECT k.conname, pg_get_constraintdef(k.oid) AS definition
        FROM pg_constraint k
        JOIN pg_class c ON c.oid = k.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2
      SQL
      normalized = normalize_definition(definition)
      next if local_constraints.any? { |row| normalize_definition(row["definition"]) == normalized }

      local_names = local_constraints.map { |row| row["conname"] }.to_set
      name = available_name(fk[:name], local_names)
      begin
        @dest.exec(<<~SQL)
          ALTER TABLE ONLY #{dest_table(fk[:table_name])}
          ADD CONSTRAINT #{quote_ident(name)} #{definition} NOT VALID
        SQL
      rescue PG::Error => e
        warn "\n  AVISO: no se pudo crear FK #{fk[:name]} en #{fk[:table_name]}: #{e.message}"
      end
    end

    puts "\n  FKs omitidas por tablas no presentes: #{skipped}" if skipped.positive?
  end

  def foreign_key_definition(fk, ref_schema)
    sql = +"FOREIGN KEY (#{fk[:columns]}) REFERENCES "
    sql << "#{quote_ident(ref_schema)}.#{quote_ident(fk[:ref_table])} (#{fk[:ref_columns]})"

    sql << " MATCH FULL" if fk[:match_type] == "f"
    sql << match_action("ON UPDATE", fk[:update_action])
    sql << match_action("ON DELETE", fk[:delete_action])
    if fk[:deferrable]
      sql << (fk[:deferred] ? " DEFERRABLE INITIALLY DEFERRED" : " DEFERRABLE")
    end
    sql
  end

  def match_action(prefix, code)
    case code
    when "r" then " #{prefix} RESTRICT"
    when "c" then " #{prefix} CASCADE"
    when "n" then " #{prefix} SET NULL"
    when "d" then " #{prefix} SET DEFAULT"
    else ""
    end
  end

  def create_enums!
    rows = @source.exec_params(<<~SQL, [@source_schema])
      SELECT t.typname AS name, e.enumlabel AS label
      FROM pg_type t
      JOIN pg_enum e ON e.enumtypid = t.oid
      JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE n.nspname = $1
      ORDER BY t.typname, e.enumsortorder
    SQL
    rows.group_by { |row| row["name"] }.each do |name, labels|
      labels = labels.map { |row| row["label"] }
      local = @dest.exec_params(<<~SQL, [@dest_schema, name]).ntuples.positive?
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = $1 AND t.typname = $2 AND t.typtype = 'e'
      SQL

      if local
        existing = @dest.exec_params(<<~SQL, [@dest_schema, name]).map { |row| row["enumlabel"] }
          SELECT e.enumlabel
          FROM pg_type t
          JOIN pg_enum e ON e.enumtypid = t.oid
          JOIN pg_namespace n ON n.oid = t.typnamespace
          WHERE n.nspname = $1 AND t.typname = $2
          ORDER BY e.enumsortorder
        SQL
        (labels - existing).each do |label|
          @dest.exec("ALTER TYPE #{quote_ident(@dest_schema)}.#{quote_ident(name)} ADD VALUE IF NOT EXISTS #{@dest.escape_literal(label)}")
        end
      else
        values = labels.map { |label| @dest.escape_literal(label) }.join(", ")
        @dest.exec("CREATE TYPE #{quote_ident(@dest_schema)}.#{quote_ident(name)} AS ENUM (#{values})")
      end
    end
  end

  def create_sequences!
    @source_sequences = @source.exec_params(<<~SQL, [@source_schema]).map do |row|
      SELECT c.relname AS name,
             format_type(s.seqtypid, NULL) AS type,
             s.seqstart, s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle
      FROM pg_sequence s
      JOIN pg_class c ON c.oid = s.seqrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1
      ORDER BY c.relname
    SQL
      {
        name: row["name"],
        type: row["type"],
        start: row["seqstart"],
        increment: row["seqincrement"],
        min: row["seqmin"],
        max: row["seqmax"],
        cache: row["seqcache"],
        cycle: row["seqcycle"] == "t"
      }
    end

    @source_sequences.each do |sequence|
      next if local_sequence?(sequence[:name])

      sql = +"CREATE SEQUENCE #{quote_ident(@dest_schema)}.#{quote_ident(sequence[:name])}"
      sql << " AS #{rewrite_sql(sequence[:type])}"
      sql << " INCREMENT BY #{sequence[:increment]}"
      sql << " MINVALUE #{sequence[:min]}"
      sql << " MAXVALUE #{sequence[:max]}"
      sql << " START WITH #{sequence[:start]}"
      sql << " CACHE #{sequence[:cache]}"
      sql << " CYCLE" if sequence[:cycle]
      @dest.exec(sql)
    end
  end

  def local_sequence?(name)
    @dest.exec_params(<<~SQL, [@dest_schema, name]).ntuples.positive?
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'S'
    SQL
  end

  def apply_sequence_ownership!
    sequence_owners.each do |sequence_name, (table_name, column_name)|
      next unless local_table?(table_name)

      @dest.exec(<<~SQL)
        ALTER SEQUENCE #{quote_ident(@dest_schema)}.#{quote_ident(sequence_name)}
        OWNED BY #{dest_table(table_name)}.#{quote_ident(column_name)}
      SQL
    rescue PG::Error
      nil
    end
  end

  def sequence_owners
    @sequence_owners ||= begin
      rows = @source.exec_params(<<~SQL, [@source_schema]).map do |row|
        SELECT s.relname AS sequence_name, t.relname AS table_name, a.attname AS column_name
        FROM pg_depend d
        JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
        JOIN pg_class t ON t.oid = d.refobjid
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
        JOIN pg_namespace n ON n.oid = s.relnamespace
        WHERE n.nspname = $1 AND d.deptype IN ('a', 'i')
      SQL
        [row["sequence_name"], row["table_name"], row["column_name"]]
      end
      rows.to_h { |sequence_name, table_name, column_name| [sequence_name, [table_name, column_name]] }
    end
  end

  def update_sequence_values!
    return unless @source_sequences

    starts = @source_sequences.to_h { |sequence| [sequence[:name], sequence[:start]] }

    @source_sequences.each do |sequence|
      next unless local_sequence?(sequence[:name])

      owner = sequence_owners[sequence[:name]]
      next if owner.nil?

      table_name, column_name = owner
      next unless local_table?(table_name)

      dest_name = "#{quote_ident(@dest_schema)}.#{quote_ident(sequence[:name])}"
      begin
        max_value = @dest.exec(
          "SELECT MAX(#{quote_ident(column_name)}) FROM #{dest_table(table_name)}"
        ).getvalue(0, 0)
        if max_value.nil?
          @dest.exec_params(
            "SELECT setval($1::regclass, $2::bigint, false)",
            [dest_name, starts[sequence[:name]]]
          )
        else
          @dest.exec_params(
            "SELECT setval($1::regclass, $2::bigint, true)",
            [dest_name, max_value]
          )
        end
      rescue PG::Error => e
        warn "AVISO: no se pudo sincronizar la secuencia #{sequence[:name]}: #{e.message}"
      end
    end
  end

  def analyze_table!(table)
    @dest.exec("ANALYZE #{dest_table(table)}")
  rescue PG::Error => e
    warn "AVISO: ANALYZE fallo en #{table}: #{e.message}"
  end

  def print_summary
    puts
    puts "Resumen"
    @stats.sort.each { |action, count| puts "  #{action}: #{count}" }
    unless @errors.empty?
      puts "  Errores: #{@errors.length}"
      @errors.each { |table, message| puts "    - #{table}: #{message}" }
    end
  end

  def format_duration(seconds)
    if seconds < 60
      format("%.1fs", seconds)
    elsif seconds < 3600
      format("%dm %02ds", seconds / 60, seconds % 60)
    else
      format("%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
    end
  end

  def src_table(table)
    "#{quote_ident(@source_schema)}.#{quote_ident(table)}"
  end

  def dest_table(table)
    "#{quote_ident(@dest_schema)}.#{quote_ident(table)}"
  end

  def quote_ident(identifier)
    @dest.quote_ident(identifier)
  end
end

exit MigrateDB.new(ARGV).run
