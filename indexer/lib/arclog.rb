class ARCLog

  def self.exception(e)
    backtrace = e.backtrace.join("\n")
    self.error("\n#{e}\n#{backtrace}")
  end

  def self.prepare(s)
    s.split("\n").map {|line| "as_arclight plugin: #{line}"}.join("\n")
  end

  def self.debug(s)
    Log.debug(prepare(s)) unless $ARCLIGHT_UNIT_TESTS
  end

  def self.info(s)
    Log.info(prepare(s)) unless $ARCLIGHT_UNIT_TESTS
  end

  def self.warn(s)
    Log.warn(prepare(s)) unless $ARCLIGHT_UNIT_TESTS
  end

  def self.error(s)
    Log.error(prepare(s)) unless $ARCLIGHT_UNIT_TESTS
  end



end
