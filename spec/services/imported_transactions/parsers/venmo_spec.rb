require "rails_helper"

RSpec.describe ImportedTransactions::Parsers::Venmo do
  let(:parser) { described_class.new }

  it "parses typical Venmo payment receipt text with timestamp" do
    pdf_text = <<~TEXT
      Transaction details
      Jane Doe
      Received from @janedoe-123
      Amount: $1,400.00
      Date: Mar 1, 2026, 6:41 PM
      Transaction ID 987654321
    TEXT

    result = parser.parse(pdf_text)
    expect(result.success?).to be(true)
    data = result.value!
    expect(data.document_type).to eq("venmo")
    expect(data.payment_method).to eq("venmo")
    expect(data.payer_name).to eq("Jane Doe")
    expect(data.payer_username).to eq("@janedoe-123")
    expect(data.amount_cents).to eq(140_000)
    expect(data.occurred_on).to eq(Date.new(2026, 3, 1))
    expect(data.external_reference).to eq("987654321")
  end

  it "parses date without timestamp" do
    pdf_text = <<~TEXT
      Transaction details
      Jane Doe
      Amount: $500.00
      Date: Apr 15, 2026
      Transaction ID 12345
    TEXT

    result = parser.parse(pdf_text)
    expect(result.success?).to be(true)
    data = result.value!
    expect(data.occurred_on).to eq(Date.new(2026, 4, 15))
    expect(data.payer_username).to be_nil
  end

  it "returns nil fields when headings are missing" do
    pdf_text = "Some random text without structure"

    result = parser.parse(pdf_text)
    expect(result.success?).to be(true)
    data = result.value!
    expect(data.payer_name).to be_nil
    expect(data.payer_username).to be_nil
    expect(data.amount_cents).to be_nil
    expect(data.occurred_on).to be_nil
    expect(data.external_reference).to be_nil
  end

  it "handles parser exceptions gracefully" do
    allow(parser).to receive(:extract_payer).and_raise(StandardError, "Corrupted structure")
    result = parser.parse("corrupted")
    expect(result.failure?).to be(true)
    expect(result.failure.error_message).to eq("Corrupted structure")
  end
end
