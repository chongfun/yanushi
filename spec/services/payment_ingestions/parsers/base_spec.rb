require 'rails_helper'

RSpec.describe PaymentIngestions::Parsers::Base do
  let(:parser) { Class.new(PaymentIngestions::Parsers::Base).new }

  describe '#clean_name' do
    it 'returns nil if name is blank' do
      expect(parser.send(:clean_name, nil)).to be_nil
      expect(parser.send(:clean_name, "")).to be_nil
    end

    it 'cleans names correctly' do
      expect(parser.send(:clean_name, "John Doe!")).to eq("John Doe")
    end
  end

  describe '#parse_amount' do
    it 'returns nil if amount does not match pattern' do
      expect(parser.send(:parse_amount, "no money here")).to be_nil
    end

    it 'parses valid amounts' do
      expect(parser.send(:parse_amount, "Amount: $1,234.56")).to eq(BigDecimal("1234.56"))
    end
  end

  describe '#parse_date' do
    it 'returns nil if text cannot be parsed' do
      # This triggers the safe navigation else branch (returns nil)
      expect(parser.send(:parse_date, "not a date")).to be_nil
    end

    it 'rescues ArgumentError and returns nil' do
      # Triggers rescue block
      allow(Time.zone).to receive(:parse).and_raise(ArgumentError)
      expect(parser.send(:parse_date, "2026-01-01")).to be_nil
    end
  end

  describe '#parse' do
    it 'raises NotImplementedError' do
      expect {
        parser.parse("some text")
      }.to raise_error(NotImplementedError, /must be implemented/)
    end
  end
end
