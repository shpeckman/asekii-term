# src/asekii-term/terminal/notify.cr
module Asekii::Event
  record Notification, kind : Kind, id : String, button : Int32 = 0, untracked : Bool = false do
    enum Kind
      Activated
      Button
      Closed
    end
  end
end

class Asekii::Terminal
  SEPARATOR  = ' '
  TEXT_CHUNK = 2048

  enum Urgency
    Low
    Normal
    Critical
  end

  enum Occasion
    Always
    Unfocused
    Invisible
  end

  record Notice, title : String = "", body : String = "", id : String? = nil, app : String? = nil, types : Array(String) = [] of String, icons : Array(String) = [] of String, icon : Bytes? = nil, icon_key : String? = nil, buttons : Array(String) = [] of String, sound : String? = nil, urgency : Urgency? = nil, expires : Time::Span? = nil, occasion : Occasion = Occasion::Always, focus : Bool = true, report : Bool = false, closes : Bool = false

  NOTIFY_OSC9 = {"iterm", "ghostty", "wezterm"}
  CONTROLS    = /[\x{00}-\x{1f}\x{7f}-\x{9f}]/

  @icons    = Set(String).new
  @notifier = Atomic(Int32).new(-1)

  def notify_protocol(limit : Time::Span = @config.query_timeout) : NotifyProtocol
    chosen = @config.notifications
    return chosen unless chosen.auto?
    return NotifyProtocol::Kitty unless @config.detect
    known = @notifier.get
    return NotifyProtocol.from_value(known) if known >= 0
    found = if notification_support(limit)
              NotifyProtocol::Kitty
            elsif identity(limit).try(&.matches?(NOTIFY_OSC9))
              NotifyProtocol::Osc9
            else
              NotifyProtocol::Osc777
            end
    @notifier.set(found.value)
    found
  end

  def notify(notice : Notice) : String
    id       = ident(notice.id || UUID.random.to_s)
    protocol = notify_protocol
    return plain_notify(id, notice, protocol) unless protocol.kitty?
    cache   = notice.icon_key.try { |key| ident(key) }
    actions = "#{"report," if notice.report}#{"-" unless notice.focus}focus"
    meta = Asekii::Terminal.build do |wire|
      wire.str("i=").str(id)
      wire.field(":a=", actions) unless actions == "focus"
      wire.str(":c=1") if notice.closes
      notice.app.try { |app| wire.str(":f=").base64(app) }
      notice.types.each { |type| wire.str(":t=").base64(type) }
      notice.icons.each { |icon| wire.str(":n=").base64(icon) }
      wire.field(":g=", cache)
      wire.field(":o=", notice.occasion.to_s.downcase) unless notice.occasion.always?
      notice.sound.try { |sound| wire.str(":s=").base64(sound) }
      wire.field(":u=", notice.urgency.try(&.value))
      wire.field(":w=", notice.expires.try(&.total_milliseconds.to_i))
    end
    exclusive(Family::Notify) do
      parts = [] of {String, Bytes}
      slices(notice.title.to_slice, true).each { |chunk| parts << {"title", chunk} }
      slices(notice.body.to_slice, true).each { |chunk| parts << {"body", chunk} }
      slices(notice.buttons.join(SEPARATOR).to_slice, true).each { |chunk| parts << {"buttons", chunk} }
      icon = notice.icon
      if icon && !(cache && @icons.includes?(cache))
        slices(icon, false).each { |chunk| parts << {"icon", chunk} }
        cache.try { |key| @icons << key }
      end
      parts << {"title", Bytes.empty} if parts.empty?
      sequence = Asekii::Terminal.build do |wire|
        parts.each_with_index do |(type, chunk), index|
          wire.osc(99)
          index == 0 ? wire.str(meta) : wire.str("i=").str(id)
          wire.field(":p=", type) unless type == "title"
          wire.str(":e=1") unless chunk.empty?
          wire.field(":g=", cache) if type == "icon" && index > 0
          wire.str(":d=0") unless index == parts.size - 1
          wire.semi.base64(chunk).st
        end
      end
      @output.send(sequence)
    end
    id
  end

  def notify(title : String, body : String = "", **options) : String
    notify(Notice.new(**options, title: title, body: body))
  end

  def close_notification(id : String) : Nil
    return unless notify_protocol.kitty?
    exclusive(Family::Notify) { @output.send(Asekii::Terminal.build { |wire| wire.osc(99).str("i=").str(ident(id)).str(":p=close;").st }) }
  end

  def notifications_alive(limit : Time::Span = @config.query_timeout) : Array(String)?
    return unless notify_protocol(limit).kitty?
    id = UUID.random.to_s
    request(Query::NotifyAlive, Asekii::Terminal.build { |wire| wire.osc(99).str("i=").str(id).str(":p=alive;").st }, limit, id).as?(Array(String))
  end

  def notification_support(limit : Time::Span = @config.query_timeout) : Hash(String, Array(String))?
    id = UUID.random.to_s
    request(Query::NotifySupport, Asekii::Terminal.build { |wire| wire.osc(99).str("i=").str(id).str(":p=?;").st }, limit, id, true).as?(Hash(String, Array(String)))
  end

  private def plain_notify(id : String, notice : Notice, protocol : NotifyProtocol) : String
    title = notice.title.gsub(CONTROLS, ' ')
    body  = notice.body.gsub(CONTROLS, ' ')
    sequence = Asekii::Terminal.build do |wire|
      if protocol.osc9?
        wire.osc(9).str(title.empty? ? body : body.empty? ? title : "#{title}: #{body}").st
      else
        wire.osc(777).str("notify;").str(title.tr(";", ",")).semi.str(body).st
      end
    end
    exclusive(Family::Notify) { @output.send(sequence) }
    id
  end

  private def slices(data : Bytes, text : Bool) : Array(Bytes)
    chunks = [] of Bytes
    offset = 0
    while offset < data.size
      size = Math.min(TEXT_CHUNK, data.size - offset)
      if text
        while size > 1 && offset + size < data.size && data[offset + size] & 0xc0 == 0x80
          size -= 1
        end
      end
      chunks << data[offset, size]
      offset += size
    end
    chunks
  end

  private def notified(meta : Hash(String, String), payload : String) : Nil
    id = meta["i"]? || "0"
    case meta["p"]?
    when "?"
      route(Query::NotifySupport, fields(payload).transform_values(&.split(',')), id)
    when "alive"
      route(Query::NotifyAlive, payload.split(',', remove_empty: true), id)
    when "close"
      push Event::Notification.new(:closed, id, untracked: payload == "untracked")
    when nil, "title"
      button = payload.to_i? || 0
      push Event::Notification.new(button > 0 ? Event::Notification::Kind::Button : Event::Notification::Kind::Activated, id, button)
    end
  end
end
