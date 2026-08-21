require "rails_helper"

RSpec.describe ImportedTransactions::Parsers::ChaseStatement do
  let(:parser) { described_class.new }

  it "parses typical Chase statement Zelle and P2P lines and infers year" do
    pdf_text = <<~TEXT
      March 18, 2026 through April 16, 2026
      TRANSACTION DETAIL
      DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
      03/24     Zelle Payment From Sam Lopez Pncaa0Yqh12Q                            1,300.00        2,850.00
      04/01     Oak Vly Com Bnk  P2P        John Doe     Web ID: 3270262278                   1,000.00        3,700.00
    TEXT

    results = parser.parse(pdf_text)
    expect(results.size).to eq(2)

    # First transaction (Zelle)
    r1 = results[0]
    expect(r1.success?).to be(true)
    expect(r1.value!.document_type).to eq("chase_statement")
    expect(r1.value!.payment_method).to eq("zelle")
    expect(r1.value!.payer_name).to eq("Sam Lopez")
    expect(r1.value!.amount_cents).to eq(130_000)
    expect(r1.value!.occurred_on).to eq(Date.new(2026, 3, 24))
    expect(r1.value!.external_reference).to eq("Pncaa0Yqh12Q")

    # Second transaction (P2P ACH)
    r2 = results[1]
    expect(r2.success?).to be(true)
    expect(r2.value!.document_type).to eq("chase_statement")
    expect(r2.value!.payment_method).to eq("p2p")
    expect(r2.value!.payer_name).to eq("John Doe")
    expect(r2.value!.amount_cents).to eq(100_000)
    expect(r2.value!.occurred_on).to eq(Date.new(2026, 4, 1))
    expect(r2.value!.external_reference).to be_nil
    expect(r2.value!.raw_text).to include("Web ID: 3270262278")
  end

  it "parses multiple distinct P2P credits sharing the same Web ID across different dates and amounts" do
    pdf_text = <<~TEXT
      July 01, 2026 through July 31, 2026
      TRANSACTION DETAIL
      DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
      07/02     Oak Vly Com Bnk  P2P        Alice Smith  Web ID: 9000000021                     300.00        1,300.00
      07/15     Oak Vly Com Bnk  P2P        Alice Smith  Web ID: 9000000021                     200.00        1,500.00
      07/18     Oak Vly Com Bnk  P2P        Alice Smith  Web ID: 9000000021                   1,100.00        2,600.00
    TEXT

    results = parser.parse(pdf_text)
    expect(results.size).to eq(3)
    expect(results.all?(&:success?)).to be(true)

    expect(results[0].value!.amount_cents).to eq(30_000)
    expect(results[0].value!.occurred_on).to eq(Date.new(2026, 7, 2))
    expect(results[0].value!.external_reference).to be_nil

    expect(results[1].value!.amount_cents).to eq(20_000)
    expect(results[1].value!.occurred_on).to eq(Date.new(2026, 7, 15))
    expect(results[1].value!.external_reference).to be_nil

    expect(results[2].value!.amount_cents).to eq(110_000)
    expect(results[2].value!.occurred_on).to eq(Date.new(2026, 7, 18))
    expect(results[2].value!.external_reference).to be_nil
  end

  it "infers years correctly during December-January rollover" do
    pdf_text = <<~TEXT
      December 15, 2025 through January 14, 2026
      TRANSACTION DETAIL
      12/20     Zelle Payment From Sam Lopez Pncaa0Zqh13Q                            1,300.00        2,850.00
      01/05     Zelle Payment From Diana T Gonzales 53459101964                                 1,200.00        4,050.00
    TEXT

    results = parser.parse(pdf_text)
    expect(results.size).to eq(2)

    expect(results[0].value!.occurred_on).to eq(Date.new(2025, 12, 20))
    expect(results[1].value!.occurred_on).to eq(Date.new(2026, 1, 5))
  end

  it "returns nil occurred_on when statement period is missing (never guesses Date.current)" do
    pdf_text = <<~TEXT
      03/24     Zelle Payment From Sam Lopez Pncaa0Yqh12Q                            1,300.00        2,850.00
    TEXT
    results = parser.parse(pdf_text)
    expect(results.first.value!.occurred_on).to be_nil
  end

  it "returns nil occurred_on for invalid calendar date" do
    pdf_text = <<~TEXT
      March 18, 2026 through April 16, 2026
      TRANSACTION DETAIL
      02/30     Zelle Payment From Sam Lopez Pncaa0Yqh12Q                            1,300.00        2,850.00
    TEXT
    results = parser.parse(pdf_text)
    expect(results.size).to eq(1)
    expect(results.first.value!.occurred_on).to be_nil
  end

  it "handles parser exceptions gracefully" do
    allow(parser).to receive(:resolve_date).and_raise(StandardError, "Corrupted date resolver")
    pdf_text = <<~TEXT
      March 18, 2026 through April 16, 2026
      TRANSACTION DETAIL
      03/24     Zelle Payment From Sam Lopez Pncaa0Yqh12Q                            1,300.00        2,850.00
    TEXT

    results = parser.parse(pdf_text)
    expect(results.size).to eq(1)
    expect(results.first.failure?).to be(true)
    expect(results.first.failure.error_message).to eq("Corrupted date resolver")
  end
end
