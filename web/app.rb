# web/app.rb
require 'sinatra/base'
require 'sqlite3'
require 'json'
require 'digest'
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
end
