require "test_helper"

class ChaseStatementTest < ActiveSupport::TestCase
  setup do
    @parser = PaymentIngestions::Parsers::ChaseStatement.new
  end

  test "parses typical Chase statement Zelle and P2P lines and infers year" do
    pdf_text = <<~TEXT
      March 18, 2026 through April 16, 2026
      TRANSACTION DETAIL
      DATE     DESCRIPTION                                                                       AMOUNT          BALANCE
      03/24     Zelle Payment From Sam Lopez Pncaa0Yqh12Q                            1,300.00        2,850.00
      04/01     Oak Vly Com Bnk  P2P        John Doe     Web ID: 3270262278                   1,000.00        3,700.00
    TEXT

    results = @parser.parse(pdf_text)
    assert_equal 2, results.size

    # First transaction (Zelle)
    r1 = results[0]
    assert r1.success?
    assert_equal "chase_statement", r1.receipt_type
    assert_equal "zelle", r1.payment_method
    assert_equal "Sam Lopez", r1.payer_name
    assert_equal BigDecimal("1300.00"), r1.amount
    assert_equal Date.new(2026, 3, 24), r1.payment_date
    assert_equal "Pncaa0Yqh12Q", r1.transaction_number

    # Second transaction (P2P ACH)
    r2 = results[1]
    assert r2.success?
    assert_equal "chase_statement", r2.receipt_type
    assert_equal "p2p", r2.payment_method
    assert_equal "John Doe", r2.payer_name
    assert_equal BigDecimal("1000.00"), r2.amount
    assert_equal Date.new(2026, 4, 1), r2.payment_date
    assert_equal "3270262278", r2.transaction_number
  end

  test "infers years correctly during December-January rollover" do
    pdf_text = <<~TEXT
      December 15, 2025 through January 14, 2026
      TRANSACTION DETAIL
      12/20     Zelle Payment From Sam Lopez Pncaa0Zqh13Q                            1,300.00        2,850.00
      01/05     Zelle Payment From Diana T Gonzales 53459101964                                 1,200.00        4,050.00
    TEXT

    results = @parser.parse(pdf_text)
    assert_equal 2, results.size

    # 12/20 transaction -> should resolve to 2025
    assert_equal Date.new(2025, 12, 20), results[0].payment_date

    # 01/05 transaction -> should resolve to 2026
    assert_equal Date.new(2026, 1, 5), results[1].payment_date
  end
end
