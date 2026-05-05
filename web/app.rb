# web/app.rb
require 'sinatra/base'
require 'sqlite3'
require 'json'
require 'faye/websocket'
require 'eventmachine'

class TranscriptionWeb < Sinatra::Base
  set :public_folder, File.expand_path('assets', __dir__)
  set :views, File.expand_path('views', __dir__)

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
