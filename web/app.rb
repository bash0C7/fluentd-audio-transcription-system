# web/app.rb
require 'sinatra/base'
require 'sqlite3'
require 'json'
require 'digest'
require 'fileutils'
require 'faye/websocket'
require 'eventmachine'

class TranscriptionWeb < Sinatra::Base
  set :public_folder, File.expand_path('assets', __dir__)
  set :views, File.expand_path('views', __dir__)
  # Cache-busting query for /app.rb: PicoRuby:wasm caches the fetched
  # Ruby source as bytecode in the browser. Sinatra's static serve for
  # /app.rb only emits ETag, which browsers can still use to revalidate
  # but the Workers/Service Worker layer in some setups can serve a
  # stale bundle. Embedding a content hash in the URL forces a new fetch
  # on every deploy. Computed once at process boot; restart updates it.
  set :app_rb_version,
      Digest::SHA256.hexdigest(File.read(File.expand_path('assets/app.rb', __dir__)))[0, 12]

  WEBSOCKETS = []

  configure do
    Faye::WebSocket.load_adapter('puma')
  end

  helpers do
    def db
      @db ||= SQLite3::Database.new(ENV.fetch('DB_PATH', 'db/meeting_log.sqlite'), readonly: true).tap do |d|
        d.results_as_hash = true
      end
    end

    def spool_dir
      ENV.fetch('SPOOL_DIR',
        '/Users/bash/Library/Application Support/audio-transcription/spool')
    end

    def append_control(kind)
      path = File.join(spool_dir, 'control.jsonl')
      File.open(path, 'a') do |f|
        f.write({ ts: Time.now.to_f, kind: kind }.to_json + "\n")
      end
    end
  end

  post '/api/session/boundary' do
    append_control('boundary')
    status 202
    content_type :json
    { status: 'queued' }.to_json
  end

  post '/api/session/mute' do
    append_control('mute_toggle')
    status 202
    content_type :json
    { status: 'queued' }.to_json
  end

  get '/api/session/current' do
    content_type :json
    row = db.get_first_row(<<~SQL)
      SELECT id, started_at, ended_at, status FROM sessions
      WHERE status='active' ORDER BY started_at DESC LIMIT 1
    SQL
    halt 404 unless row
    row.to_json
  end

  get '/api/session/recent' do
    content_type :json
    rows = db.execute(<<~SQL, [10])
      SELECT id, started_at, ended_at, status FROM sessions
      ORDER BY started_at DESC LIMIT ?
    SQL
    rows.to_json
  end

  get '/' do
    erb :index
  end

  get '/api/recent' do
    content_type :json
    since = params[:since].to_f
    {
      transcripts: db.execute("SELECT * FROM transcripts WHERE ended_at > ? ORDER BY started_at DESC LIMIT 200", [since]),
      edges: db.execute("SELECT src, dst, weight, last_observed_at FROM entity_edges ORDER BY last_observed_at DESC LIMIT 500")
    }.to_json
  end

  get '/api/sessions/:id' do
    content_type :json
    session = db.get_first_row("SELECT * FROM sessions WHERE id=?", [params[:id].to_i])
    halt 404 unless session
    transcripts = db.execute("SELECT * FROM transcripts WHERE session_id=? ORDER BY started_at", [params[:id].to_i])
    { session: session, transcripts: transcripts }.to_json
  end

  get '/api/audio/:id' do
    row = db.get_first_row("SELECT blob, codec FROM audio_segments WHERE id=?", [params[:id].to_i])
    halt 404 unless row
    content_type 'audio/x-caf'
    row['blob']
  end

  post '/_internal/notify' do
    body = JSON.parse(request.body.read)
    msg = body.to_json
    WEBSOCKETS.each { |ws| ws.send(msg) }
    'ok'
  end

  get '/stream' do
    if Faye::WebSocket.websocket?(env)
      ws = Faye::WebSocket.new(env)
      ws.on(:open) { WEBSOCKETS << ws }
      ws.on(:close) { WEBSOCKETS.delete(ws); ws = nil }
      ws.rack_response
    else
      halt 426
    end
  end

  class RetranscribeWorker
    def initialize(db_path:, run_dir:, spawn: nil)
      @db_path = db_path
      @run_dir = run_dir
      @spawn = spawn || ->(sid) {
        bin = ENV.fetch('SWIFTCAP_BIN', 'swiftcap')
        env = {
          'SWIFTCAP_SPOOL' => ENV['SPOOL_DIR'],
          'DB_PATH' => ENV['DB_PATH']
        }.compact
        Process.spawn(env, bin, 'retranscribe', '--session-id', sid.to_s,
                      out: STDOUT, err: STDERR)
      }
      FileUtils.mkdir_p(@run_dir)
    end

    def pick_one
      db = SQLite3::Database.new(@db_path)
      begin
        row = db.get_first_row(<<~SQL)
          SELECT id FROM sessions WHERE status='finalized'
          ORDER BY ended_at ASC LIMIT 1
        SQL
        return nil unless row
        sid = row[0]
        pidfile = File.join(@run_dir, "retranscribe-#{sid}.pid")
        if File.exist?(pidfile) && pid_alive?(File.read(pidfile).to_i)
          return sid
        end
        db.execute("UPDATE sessions SET status='transcribing' WHERE id=?", [sid])
        begin
          pid = @spawn.call(sid)
          File.write(pidfile, pid.to_s)
          Process.detach(pid) if pid > 0
        rescue StandardError => e
          db.execute("UPDATE sessions SET status='finalized' WHERE id=?", [sid])
          File.delete(pidfile) if File.exist?(pidfile)
          raise e
        end
        sid
      ensure
        db.close
      end
    end

    private

    def pid_alive?(pid)
      return false if pid <= 0
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end
end

unless ENV['SKIP_RETRANSCRIBE_WORKER']
  Thread.new do
    worker = TranscriptionWeb::RetranscribeWorker.new(
      db_path: ENV.fetch('DB_PATH', 'db/meeting_log.sqlite'),
      run_dir: File.expand_path('../tmp/run', __dir__))
    loop do
      begin
        worker.pick_one
      rescue StandardError => e
        warn "retranscribe worker error: #{e.class}: #{e.message}"
      end
      sleep 5
    end
  end
end
