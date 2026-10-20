# src/asekii/terminal/indicators.cr
class Asekii::Terminal
  TITLE_SAVE     = "\e[22;0t"
  TITLE_RESTORE  = "\e[23;0t"
  BELL           = "\a"
  PROGRESS_CLEAR = "\e]9;4;0\e\\"

  enum Progress
    Normal        = 1
    Error         = 2
    Indeterminate = 3
    Paused        = 4
  end

  @title    : String?
  @progress : String?

  def title=(text : String) : String
    clean = text.gsub(CONTROLS, ' ')
    sequence = @wire.synchronize do
      saved  = @title.nil?
      @title = clean
      "#{saved ? TITLE_SAVE : ""}\e]2;#{clean}\e\\"
    end
    @output.send(sequence)
    text
  end

  def title : String?
    @wire.synchronize { @title }
  end

  def reset_title : Nil
    sequence = @wire.synchronize do
      held   = @title
      @title = nil
      held ? TITLE_RESTORE : ""
    end
    @output.send(sequence) unless sequence.empty?
  end

  def bell : Nil
    @output.send(BELL)
  end

  def progress(value : Float64 = 0.0, state : Progress = Progress::Normal) : Nil
    percent  = (value.clamp(0.0, 1.0) * 100).round.to_i
    sequence = state.indeterminate? ? "\e]9;4;3\e\\" : "\e]9;4;#{state.value};#{percent}\e\\"
    @wire.synchronize { @progress = sequence }
    @output.send(sequence)
  end

  def clear_progress : Nil
    shown = @wire.synchronize do
      held      = @progress
      @progress = nil
      !held.nil?
    end
    @output.send(PROGRESS_CLEAR) if shown
  end

  private def indicators_off : String
    "#{@progress ? PROGRESS_CLEAR : ""}#{@title ? TITLE_RESTORE : ""}"
  end

  private def indicators_on : String
    title = @title
    "#{title ? "#{TITLE_SAVE}\e]2;#{title}\e\\" : ""}#{@progress}"
  end
end
