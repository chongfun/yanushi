require 'rails_helper'

RSpec.describe PaymentIngestions::IngestionResult do
  let(:valid_attributes) do
    {
      payer_name: "John Doe",
      payer_username: "@johndoe",
      amount: BigDecimal("100.00"),
      payment_date: Date.new(2026, 1, 1),
      payment_method: "zelle",
      transaction_number: "TXN123",
      receipt_type: "zelle",
      raw_text: "some raw pdf text",
      error_message: nil,
      success: true
    }
  end

  describe '#success?' do
    it 'returns true when success is true and error_message is nil' do
      result = described_class.new(valid_attributes)
      expect(result.success?).to be_truthy
    end

    it 'returns false when success is false' do
      result = described_class.new(valid_attributes.merge(success: false))
      expect(result.success?).to be_falsey
    end

    it 'returns false when error_message is present' do
      result = described_class.new(valid_attributes.merge(error_message: "some parsing failure"))
      expect(result.success?).to be_falsey
    end
  end

  describe '#to_h' do
    it 'returns a hash with expected attributes' do
      result = described_class.new(valid_attributes)
      hash = result.to_h

      expect(hash[:payer_name]).to eq("John Doe")
      expect(hash[:payer_username]).to eq("@johndoe")
      expect(hash[:amount]).to eq(BigDecimal("100.00"))
      expect(hash[:payment_date]).to eq(Date.new(2026, 1, 1))
      expect(hash[:payment_method]).to eq("zelle")
      expect(hash[:transaction_number]).to eq("TXN123")
      expect(hash[:receipt_type]).to eq("zelle")
      expect(hash[:raw_text]).to eq("some raw pdf text")
      expect(hash[:error_message]).to be_nil
      expect(hash).not_to have_key(:success) # success is not serialized in to_h
    end
  end
end
