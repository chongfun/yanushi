require 'rails_helper'

RSpec.describe PaymentIngestions::Parsers::Venmo do
  let(:parser) { PaymentIngestions::Parsers::Venmo.new }

  describe '#parse' do
    it 'parses a typical Venmo receipt correctly' do
      pdf_text = <<~TEXT
        Transaction details
        Jane Doe
        Received from @janedoe
        $1,000.00
        Mar 1, 2024, 6:41 PM
        Transaction ID 9991209384910283
      TEXT

      result = parser.parse(pdf_text)
      expect(result.success?).to be_truthy
      expect(result.value!.payer_name).to eq("Jane Doe")
      expect(result.value!.payer_username).to eq("@janedoe")
      expect(result.value!.amount).to eq(BigDecimal("1000.00"))
      expect(result.value!.payment_date).to eq(Date.new(2024, 3, 1))
      expect(result.value!.transaction_number).to eq("9991209384910283")
    end

    it 'returns nil for payer_name if header is missing' do
      pdf_text = "No header here\nJane Doe"
      expect(parser.send(:extract_payer, pdf_text)).to be_nil
    end

    it 'returns nil for payer_username if match is missing' do
      pdf_text = "No username here"
      expect(parser.send(:extract_username, pdf_text)).to be_nil
    end

    it 'returns nil for transaction_id if match is missing' do
      pdf_text = "No txn id here"
      expect(parser.send(:extract_transaction_id, pdf_text)).to be_nil
    end

    describe 'extract_date' do
      it 'parses date without timestamp' do
        pdf_text = "Mar 1, 2024"
        expect(parser.send(:extract_date, pdf_text)).to eq(Date.new(2024, 3, 1))
      end

      it 'returns nil if date is completely missing' do
        pdf_text = "no date here"
        expect(parser.send(:extract_date, pdf_text)).to be_nil
      end
    end
  end
end
