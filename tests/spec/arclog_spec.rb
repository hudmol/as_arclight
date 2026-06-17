require_relative '../../indexer/lib/arclog'

describe Arclight::ArchivalObjectMapper do

  context 'ARCLog plugin logging' do

    around(:each) do |example|
      $ARCLIGHT_UNIT_TESTS = false
      example.run
      $ARCLIGHT_UNIT_TESTS = true
    end

    it 'logs at various levels and applies a prefix' do
      [:debug, :info, :warn, :error].each do |level|
        allow(Log).to receive(level)
        ARCLog.send(level, level.to_s)

        expect(Log).to have_received(level).with("as_arclight plugin: #{level}")
      end
    end

    it 'logs exceptions too' do
      error = RuntimeError.new("whoops")
      error.set_backtrace(caller)

      allow(Log).to receive(:error)
      ARCLog.exception(error)

      expect(Log).to have_received(:error).with(
                       satisfy {|msg|
                         msg.split("\n").all? {|s|
                           s.start_with?("as_arclight plugin:")
                         }
                       })
    end
  end

end
