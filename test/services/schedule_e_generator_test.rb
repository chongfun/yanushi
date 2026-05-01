require "test_helper"

class ScheduleEGeneratorTest < ActiveSupport::TestCase
  # Each expense category with a distinct dollar amount so we can assert
  # each lands in the correct PDF field independently.
  EXPENSE_AMOUNTS = {
    "advertising"                       => 100,
    "auto_and_travel"                   => 200,
    "cleaning_and_maintenance"          => 300,
    "commissions"                       => 400,
    "insurance"                         => 500,
    "legal_and_other_professional_fees" => 600,
    "management_fees"                   => 700,
    "mortgage_interest"                 => 800,
    "other_interest"                    => 900,
    "repairs"                           => 1000,
    "supplies"                          => 1100,
    "taxes"                             => 1200,
    "utilities"                         => 1300,
    "depreciation_expense"              => 1400,
    "other"                             => 1500
  }.freeze

  RENT_AMOUNT    = 12_000
  UTILITY_AMOUNT = 250
  TEST_YEAR      = 2026

  setup do
    @property = rental_properties(:one)
    @year = TEST_YEAR
    date_in_year = Date.new(TEST_YEAR, 6, 1)

    # Create one expense per category
    EXPENSE_AMOUNTS.each do |category, amount|
      Expense.create!(
        rental_property: @property,
        category: category,
        amount: amount,
        expense_date: date_in_year,
        description: "Test #{category}"
      )
    end

    # Create a rent payment within the year
    scheduled_rent = scheduled_rents(:one)
    RentPayment.create!(
      scheduled_rent: scheduled_rent,
      payment_date: date_in_year,
      amount: RENT_AMOUNT,
      payment_method: "check",
      transaction_number: "TEST001"
    )

    # Create a utility payment within the year (attached to a lease on this property)
    lease = leases(:one)
    UtilityPayment.create!(
      lease: lease,
      amount: UTILITY_AMOUNT,
      payment_date: date_in_year
    )

    # Compute the actual totals the generator will see (includes any fixture data
    # that also falls within the year, e.g., existing rent_payments fixtures).
    date_range = Date.new(TEST_YEAR, 1, 1)..Date.new(TEST_YEAR, 12, 31)
    @expected_rents     = @property.rent_payments.where(payment_date: date_range).sum(:amount).to_i
    @expected_utilities = @property.utility_payments.where(payment_date: date_range).sum(:amount).to_i

    # Per-category totals (includes any same-category fixture expenses)
    @expected_by_category = @property.expenses
                              .where(expense_date: date_range)
                              .group(:category)
                              .sum(:amount)
                              .transform_values(&:to_i)
  end

  # -----------------------------------------------------------------------
  # Basic validity
  # -----------------------------------------------------------------------

  test "generates a valid PDF binary" do
    pdf_data = ScheduleEGenerator.new(@property, @year).call

    assert pdf_data.present?
    assert pdf_data.start_with?("%PDF"), "Output should start with PDF magic bytes"
    assert pdf_data.bytesize > 1000
  end

  test "generates PDF for year with no data" do
    pdf_data = ScheduleEGenerator.new(@property, 2020).call

    assert pdf_data.present?
    assert pdf_data.start_with?("%PDF")
  end

  test "accepts year as string" do
    pdf_data = ScheduleEGenerator.new(@property, TEST_YEAR.to_s).call

    assert pdf_data.present?
    assert pdf_data.start_with?("%PDF")
  end

  # -----------------------------------------------------------------------
  # Field-by-field assertions
  # -----------------------------------------------------------------------

  test "all expense categories and income fields are populated correctly" do
    require "hexapdf"

    pdf_data = ScheduleEGenerator.new(@property, @year).call
    doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))

    def read_field(doc, name)
      f = doc.acro_form.field_by_name(name)
      f&.field_value&.to_s
    end

    map = ScheduleEGenerator::FIELD_MAP

    # Property address
    assert_equal @property.address,
                 read_field(doc, map[:property_address]),
                 "property_address field should match"

    # Pre-calculate raw sums for the year to use in total assertions
    date_range = Date.new(TEST_YEAR, 1, 1)..Date.new(TEST_YEAR, 12, 31)
    raw_rents = @property.rent_payments.where(payment_date: date_range).sum(:amount)
    raw_utilities = @property.utility_payments.where(payment_date: date_range).sum(:amount)
    raw_expenses  = @property.expenses.where(expense_date: date_range).sum(:amount)

    # Line 3 — Rents received
    actual_rents = read_field(doc, map[:rents_received])
    expected_rents_with_utilities = (raw_rents + raw_utilities).to_i
    assert_equal expected_rents_with_utilities.to_s, actual_rents,
                 "rents_received (Line 3) should equal #{expected_rents_with_utilities}"

    # Lines 5–19 — Each expense category should be in its correct PDF field.
    # Uses @expected_by_category which includes any fixture data for that category.
    Expense.categories.each_key do |category|
      expected = @expected_by_category[category] || 0
      next if expected.zero? # skip categories with no data

      field_key = ScheduleEGenerator::CATEGORY_TO_FIELD[category]
      actual = read_field(doc, map[field_key])

      assert_equal expected.to_s, actual,
                   "#{category} (Line #{field_key}) should be #{expected}, got #{actual.inspect}"
    end

    # Line 20 — Total expenses
    total_expenses_expected = raw_expenses.to_i

    actual_total_expenses = read_field(doc, map[:total_expenses])
    assert_equal total_expenses_expected.to_s, actual_total_expenses,
                 "total_expenses (Line 20) should be #{total_expenses_expected}"

    # Line 21 — Net income
    # Generator: rents_received (rents + utilities) - total_expenses
    net_expected = (raw_rents + raw_utilities - raw_expenses).to_i

    actual_net = read_field(doc, map[:net_income])
    assert_equal net_expected.to_s, actual_net,
                 "net_income (Line 21) should be #{net_expected}"

    # Line 23a — Sum of all Line 3 (rents received + utility reimbursements)
    expected_rents_total = (raw_rents + raw_utilities).to_i
    assert_equal expected_rents_total.to_s,
                 read_field(doc, map[:line_23a]),
                 "line_23a should equal total rents received (#{expected_rents_total})"

    # Line 23e — Sum of all Line 20 (total expenses)
    assert_equal total_expenses_expected.to_s,
                 read_field(doc, map[:line_23e]),
                 "line_23e should equal total expenses (#{total_expenses_expected})"

    # Line 24 — Sum of positive Line 21 amounts (only filled when income > 0)
    assert net_expected >= 0, "Expected net income for this test property (got #{net_expected})"
    assert_equal net_expected.to_s, read_field(doc, map[:line_24]),
                 "line_24 should equal the positive Line 21 amount (#{net_expected})"

    # Line 25 — blank when there is net income
    assert_nil doc.acro_form.field_by_name(map[:line_25])&.field_value,
               "line_25 should be blank when there is net income"
  end

  test "property type is filled with IRS code" do
    require "hexapdf"

    pdf_data = ScheduleEGenerator.new(@property, @year).call
    doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))

    map = ScheduleEGenerator::FIELD_MAP
    type_code = doc.acro_form.field_by_name(map[:property_type])&.field_value&.to_s

    # residential => "1" per PROPERTY_TYPE_CODES
    assert_equal "1", type_code, "residential property should map to IRS code '1'"
  end

  test "net loss is filled when expenses exceed income" do
    require "hexapdf"

    # Create a property with no income but a large expense
    property = rental_properties(:two)
    Expense.create!(
      rental_property: property,
      category: "repairs",
      amount: 5000,
      expense_date: Date.new(@year, 3, 1),
      description: "Big repair"
    )

    pdf_data = ScheduleEGenerator.new(property, @year).call
    doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
    map = ScheduleEGenerator::FIELD_MAP

    net_income_field = doc.acro_form.field_by_name(map[:net_income])&.field_value&.to_s
    net_loss_field   = doc.acro_form.field_by_name(map[:net_loss])&.field_value&.to_s

    # Loss scenario: net_income field should be blank, net_loss should have value
    # Account for any existing income/expenses in the fixtures for the year
    date_range = Date.new(@year, 1, 1)..Date.new(@year, 12, 31)
    fixture_income = property.rent_payments.where(payment_date: date_range).sum(:amount) +
                     property.utility_payments.where(payment_date: date_range).sum(:amount)
    total_expenses = property.expenses.where(expense_date: date_range).sum(:amount)
    expected_loss = (total_expenses - fixture_income).to_i

    assert_equal expected_loss.to_s, net_loss_field,
                 "net_loss (Line 22) should be #{expected_loss} when expenses exceed income"
    assert_nil doc.acro_form.field_by_name(map[:net_income])&.field_value,
               "net_income (Line 21) should be blank when there is a net loss"

    # Line 24 must be blank for a loss (only positive Line 21 amounts go here)
    assert_nil doc.acro_form.field_by_name(map[:line_24])&.field_value,
               "line_24 (Line 24) should be blank when there is a net loss"

    # Line 25 must be filled with the loss amount
    assert_equal expected_loss.to_s, doc.acro_form.field_by_name(map[:line_25])&.field_value&.to_s,
               "line_25 (Line 25) should equal the loss amount"
  end
end
