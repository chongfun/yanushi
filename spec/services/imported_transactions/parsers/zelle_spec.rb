require "rails_helper"

RSpec.describe ImportedTransactions::Parsers::Zelle do
  let(:parser) { described_class.new }

  it "parses typical Chase Zelle payment receipt PDF text" do
    pdf_text = <<~TEXT
      Completed                         JANE DOE
      In moments
      Amount: $1,250.00
      Date: Mar 24, 2026
      Transaction number 123456789
    TEXT

    result = parser.parse(pdf_text)
    expect(result.success?).to be(true)
    data = result.value!
    expect(data.document_type).to eq("zelle")
    expect(data.payment_method).to eq("zelle")
    expect(data.payer_name).to eq("JANE DOE")
    expect(data.amount_cents).to eq(125_000)
    expect(data.occurred_on).to eq(Date.new(2026, 3, 24))
    expect(data.external_reference).to eq("123456789")
  end

  it "parses alternate 'sent you money' layout" do
    pdf_text = <<~TEXT
      John Smith sent you money
      Amount: $900.00
      Date: Apr 05, 2026
      Transaction number ZEL998877
    TEXT

    result = parser.parse(pdf_text)
    expect(result.success?).to be(true)
    data = result.value!
    expect(data.payer_name).to eq("John Smith")
    expect(data.amount_cents).to eq(90_000)
    expect(data.occurred_on).to eq(Date.new(2026, 4, 5))
    expect(data.external_reference).to eq("ZEL998877")
  end

  it "returns nil fields when headings are missing" do
    pdf_text = "Unstructured text with no headers"

    result = parser.parse(pdf_text)
    expect(result.success?).to be(true)
    data = result.value!
    expect(data.payer_name).to be_nil
    expect(data.amount_cents).to be_nil
    expect(data.occurred_on).to be_nil
    expect(data.external_reference).to be_nil
  end

  it "handles parser exceptions gracefully" do
    allow(parser).to receive(:extract_payer).and_raise(StandardError, "Unexpected error")
    result = parser.parse("corrupted")
    expect(result.failure?).to be(true)
    expect(result.failure.error_message).to eq("Unexpected error")
  end
end
