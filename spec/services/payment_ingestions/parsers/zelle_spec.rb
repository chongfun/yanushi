require 'rails_helper'

RSpec.describe PaymentIngestions::Parsers::Zelle do
  let(:parser) { PaymentIngestions::Parsers::Zelle.new }

  describe '#parse' do
    it 'parses typical Completed Zelle text' do
      pdf_text = "Completed JANE DOE In moments\n$1,300.00\nTransaction number ZELNEW202604\nDec 4, 2023"
      result = parser.parse(pdf_text)
      expect(result.success?).to be_truthy
      expect(result.payer_name).to eq("JANE DOE")
      expect(result.amount).to eq(BigDecimal("1300.00"))
      expect(result.payment_date).to eq(Date.new(2023, 12, 4))
      expect(result.transaction_number).to eq("ZELNEW202604")
    end

    it 'returns nil for payer if no patterns match' do
      pdf_text = "Some random text that doesn't say anything"
      expect(parser.send(:extract_payer, pdf_text)).to be_nil
    end

    it 'returns nil for date if missing' do
      pdf_text = "Completed JANE DOE In moments"
      expect(parser.send(:extract_date, pdf_text)).to be_nil
    end

    it 'returns nil for transaction_id if missing' do
      pdf_text = "Completed JANE DOE In moments"
      expect(parser.send(:extract_transaction_id, pdf_text)).to be_nil
    end
  end
end
