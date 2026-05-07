# web/assets/app.rb
require 'js'

# Graph is built and configured inside JS (see window.createForceGraph in
# index.erb). Two PicoRuby:wasm bridge limitations require this:
# 1. JS::Object#call(arg) maps to Function.prototype.call(arg), binding
#    arg as `this` instead of passing it positionally — so the factory
#    pattern `ForceGraph3D()(elem)` can't be expressed in PicoRuby and
#    must be invoked via a thin JS wrapper.
# 2. Ruby Floats can't cross the JS bridge as arguments
#    ("argument must be a String, Integer, or JS::Object") — so the
#    configuration calls that need float values (e.g. linkOpacity(0.4))
#    live inside the JS wrapper too.
NODES = {}
EDGES = {}
GRAPH = JS.global.createForceGraph(JS.document.getElementById('graph-canvas'))

QUICK_DIV   = JS.document.getElementById('quick-stream')
PERFECT_DIV = JS.document.getElementById('perfect-stream')

def push_quick(text)
  QUICK_DIV.querySelectorAll('.line.live').to_a.each { |n| n[:className] = 'line' }
  div = JS.document.createElement('div')
  div[:className] = 'line live'
  div[:textContent] = text
  QUICK_DIV.appendChild(div)
  while QUICK_DIV[:childElementCount].to_i > 80
    QUICK_DIV.removeChild(QUICK_DIV[:firstElementChild])
  end
end

def push_perfect(channel, raw, polished)
  div = JS.document.createElement('div')
  div[:className] = "line #{channel}"
  div[:textContent] = polished.to_s.empty? ? raw : polished
  PERFECT_DIV.appendChild(div)
  while PERFECT_DIV[:childElementCount].to_i > 200
    PERFECT_DIV.removeChild(PERFECT_DIV[:firstElementChild])
  end
end

def upsert_edge(src, dst, weight)
  return if src.nil? || dst.nil? || src == ''
  NODES[src] = { id: src, group: 'term' } unless NODES.key?(src)
  NODES[dst] = { id: dst, group: 'term' } unless NODES.key?(dst)
  key = "#{src}\t#{dst}"
  EDGES[key] = { source: src, target: dst, value: weight, ts: Time.now.to_f }
  redraw_graph
end

TAU = 1800.0

def redraw_graph
  return if GRAPH.nil?
  now = Time.now.to_f
  edges_for_js = []
  EDGES.each_pair do |_, e|
    decay = Math.exp(-(now - e[:ts]) / TAU)
    next if decay < 0.05
    edges_for_js << { source: e[:source], target: e[:target], value: e[:value] * decay }
  end
  data = JS::Bridge.to_js({ nodes: NODES.values, links: edges_for_js })
  GRAPH.graphData(data)
end

ws = JS.global[:WebSocket].new("ws://#{JS.global[:location][:host]}/stream")
ws.addEventListener('open') do |_event|
  JS.global[:console].log('[app.rb] WS open, readyState=', ws[:readyState])
end
ws.addEventListener('close') do |event|
  JS.global[:console].log('[app.rb] WS close, code=', event[:code])
end
# PicoRuby's JS bridge: prefer direct property access (parsed[:key]) over
# `.to_a + find { }` — the array-of-pairs form yields wrapped JS strings
# that don't compare equal to Ruby string literals.
ws.addEventListener('message') do |event|
  parsed = JS.global[:JSON].parse(event[:data])
  type_value = parsed[:type].to_s
  payload = parsed[:data]
  next if type_value.empty? || payload.nil?
  case type_value
  when 'quick'
    push_quick(payload[:text].to_s)
  when 'final'
    push_perfect(payload[:ch].to_s, payload[:text].to_s, '')
    entities = payload[:entities]
    if entities && !entities.nil?
      entities_arr = entities.to_a
      entities_arr.each do |left|
        entities_arr.each do |right|
          next if left == right
          upsert_edge(left[:text].to_s, right[:text].to_s, 1.0)
        end
      end
    end
  when 'polished'
    last = PERFECT_DIV[:lastElementChild]
    last[:textContent] = payload[:text].to_s if last
  when 'edge'
    upsert_edge(payload[:src].to_s, payload[:dst].to_s, payload[:weight].to_f)
  when 'session_started'
    update_session_header(payload[:session_id].to_s, payload[:session_started_at].to_i, 'active')
  when 'session_finalized'
    refresh_recent_sessions
  when 'mute_changed'
    update_mute_button(payload[:mic_muted].to_s == 'true')
  when 'retranscribe_done'
    refresh_recent_sessions
  end
end

# Session control helpers

def post_control(path)
  # JS::Bridge.to_js converts a Ruby hash to a JS object (same pattern as
  # redraw_graph uses for graph data). This allows passing method:'POST' to fetch.
  opts = JS::Bridge.to_js({ method: 'POST' })
  JS.global.fetch(path, opts)
end

def update_session_header(id, started_at, status)
  JS.document.getElementById('session-id')[:textContent] = id.to_s
  if started_at && started_at != 0
    t = JS.global[:Date].new(started_at * 1000)
    JS.document.getElementById('session-started')[:textContent] = "開始 #{t.toLocaleTimeString.to_s}"
  end
  rec = JS.document.getElementById('rec-state')
  rec[:textContent] = status == 'active' ? '●REC' : status.to_s
end

def update_mute_button(muted)
  btn = JS.document.getElementById('mute-btn')
  btn[:dataset][:muted] = muted ? 'true' : 'false'
  btn[:textContent] = muted ? '🔇 ミュート中' : '🎤 ミュート'
  rec = JS.document.getElementById('rec-state')
  rec[:className] = muted ? 'rec-state muted' : 'rec-state'
end

def refresh_recent_sessions
  JS.global.fetch('/api/session/recent') do |resp|
    resp.json.then do |arr|
      el = JS.document.getElementById('recent-sessions')
      el[:innerHTML] = ''
      arr.to_a.first(5).each do |s|
        sym = case s[:status].to_s
              when 'transcribing' then "⏳"
              when 'done'         then "✅"
              when 'finalized'    then '🟡'
              else                     "●"
              end
        span = JS.document.createElement('span')
        span[:className] = 'badge'
        span[:textContent] = "##{s[:id]} #{sym}"
        el.appendChild(span)
      end
    end
  end
end

# Bind session control button click handlers
JS.document.getElementById('boundary-btn').addEventListener('click') do |_ev|
  post_control('/api/session/boundary')
end
JS.document.getElementById('mute-btn').addEventListener('click') do |_ev|
  post_control('/api/session/mute')
end

# Bootstrap session header from current session
JS.global.fetch('/api/session/current') do |resp|
  if resp[:ok].to_s == 'true'
    resp.json.then do |s|
      update_session_header(s[:id].to_s, s[:started_at].to_i, s[:status].to_s)
    end
  end
end
refresh_recent_sessions

# Initial bootstrap from /api/recent.
# PicoRuby's JS::Object#fetch shim requires the block form (not Promise#then),
# but Response#json() is not shimmed and still returns a Promise — hence the
# inner .then.
JS.global.fetch('/api/recent?since=0') do |resp|
  resp.json.then do |data|
    transcripts = data[:transcripts].to_a
    transcripts.reverse_each do |t|
      push_perfect(t[:channel].to_s, t[:raw_text].to_s, t[:polished_text].to_s)
    end
    edges = data[:edges].to_a
    edges.each do |e|
      upsert_edge(e[:src].to_s, e[:dst].to_s, e[:weight].to_f)
    end
  end
end
