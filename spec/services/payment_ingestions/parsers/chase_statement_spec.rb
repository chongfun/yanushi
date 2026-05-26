require 'rails_helper'

RSpec.describe PaymentIngestions::Parsers::ChaseStatement do
  let(:parser) { PaymentIngestions::Parsers::ChaseStatement.new }

  it 'parses typical Chase statement Zelle and P2P lines and infers year' do
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
    expect(r1.success?).to be_truthy
    expect(r1.receipt_type).to eq("chase_statement")
    expect(r1.payment_method).to eq("zelle")
    expect(r1.payer_name).to eq("Sam Lopez")
    expect(r1.amount).to eq(BigDecimal("1300.00"))
    expect(r1.payment_date).to eq(Date.new(2026, 3, 24))
    expect(r1.transaction_number).to eq("Pncaa0Yqh12Q")

    # Second transaction (P2P ACH)
    r2 = results[1]
    expect(r2.success?).to be_truthy
    expect(r2.receipt_type).to eq("chase_statement")
    expect(r2.payment_method).to eq("p2p")
    expect(r2.payer_name).to eq("John Doe")
    expect(r2.amount).to eq(BigDecimal("1000.00"))
    expect(r2.payment_date).to eq(Date.new(2026, 4, 1))
    expect(r2.transaction_number).to eq("3270262278")
  end

  it 'infers years correctly during December-January rollover' do
    pdf_text = <<~TEXT
      December 15, 2025 through January 14, 2026
      TRANSACTION DETAIL
      12/20     Zelle Payment From Sam Lopez Pncaa0Zqh13Q                            1,300.00        2,850.00
      01/05     Zelle Payment From Diana T Gonzales 53459101964                                 1,200.00        4,050.00
    TEXT

    results = parser.parse(pdf_text)
    expect(results.size).to eq(2)

    # 12/20 transaction -> should resolve to 2025
    expect(results[0].payment_date).to eq(Date.new(2025, 12, 20))

    # 01/05 transaction -> should resolve to 2026
    expect(results[1].payment_date).to eq(Date.new(2026, 1, 5))
  end

  it 'falls back to current year when statement period is missing' do
    current_year = Date.current.year
    pdf_text = <<~TEXT
      03/24     Zelle Payment From Sam Lopez Pncaa0Yqh12Q                            1,300.00        2,850.00
    TEXT
    results = parser.parse(pdf_text)
    expect(results.first.payment_date.year).to eq(current_year)
  end

  it 'skips empty lines' do
    pdf_text = "\n\n  \n"
    results = parser.parse(pdf_text)
    expect(results).to be_empty
  end

  it 'rescues Date::Error and returns Date.current for invalid date formats' do
    pdf_text = <<~TEXT
      March 18, 2026 through April 16, 2026
      TRANSACTION DETAIL
      02/30     Zelle Payment From Sam Lopez Pncaa0Yqh12Q                            1,300.00        2,850.00
    TEXT
    results = parser.parse(pdf_text)
    expect(results.size).to eq(1)
    expect(results.first.payment_date).to eq(Date.current)
  end
end
