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

  # Representative years for each mapping group
  TEST_YEARS = [ 2025, 2022, 2021, 2018, 2015 ]

  setup do
    @property = rental_properties(:one)
    # Clear existing data to avoid overlap between tests
    TenantCharge.delete_all
    Expense.delete_all
    TenantPayment.delete_all
  end

  def create_data_for_year(year)
    date_in_year = Date.new(year, 6, 1)

    EXPENSE_AMOUNTS.each do |category, amount|
      Expense.create!(
        rental_property: @property,
        category: category,
        amount: amount,
        expense_date: date_in_year,
        description: "Test #{category} #{year}"
      )
    end

    lease = leases(:one)
    TenantPayment.create!(
      lease: lease,
      payment_date: date_in_year,
      amount: RENT_AMOUNT,
      payment_method: "check",
      transaction_number: "TEST-#{year}"
    )

    TenantPayment.create!(
      lease: lease,
      amount: UTILITY_AMOUNT,
      payment_date: date_in_year,
      payment_method: "zelle"
    )
  end

  # -----------------------------------------------------------------------
  # Basic validity and errors
  # -----------------------------------------------------------------------

  test "generates a valid PDF binary for representative years" do
    TEST_YEARS.each do |year|
      pdf_data = ScheduleEGenerator.new(@property, year).call
      assert pdf_data.present?, "PDF data for #{year} should be present"
      assert pdf_data.start_with?("%PDF"), "Output for #{year} should start with PDF magic bytes"
    end
  end

  test "raises TemplateMissingError if current year PDF is missing" do
    # 2026 is missing, and fallback is disabled
    assert_raises(ScheduleEGenerator::TemplateMissingError) do
      ScheduleEGenerator.new(@property, 2026).call
    end
  end

  test "raises TemplateMissingError if a very old year PDF is missing" do
    assert_raises(ScheduleEGenerator::TemplateMissingError) do
      ScheduleEGenerator.new(@property, 2010).call
    end
  end

  # -----------------------------------------------------------------------
  # Field population for multiple years
  # -----------------------------------------------------------------------

  test "populates fields correctly for multiple years" do
    require "hexapdf"

    TEST_YEARS.each do |year|
      create_data_for_year(year)
      generator = ScheduleEGenerator.new(@property, year)
      pdf_data = generator.call
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))

      # Use reflection to get the field map for the specific year
      map = generator.send(:field_map)

      def read_field(doc, name)
        return nil if name.nil?
        f = doc.acro_form.field_by_name(name)
        f&.field_value&.to_s
      end

      # Verify key fields
      if map[:property_address]
        assert_equal @property.address, read_field(doc, map[:property_address]), "Year #{year}: address mismatch"
      end

      if map[:rents_received]
        expected_rents = (RENT_AMOUNT + UTILITY_AMOUNT).to_s
        assert_equal expected_rents, read_field(doc, map[:rents_received]), "Year #{year}: rents mismatch"
      end

      # Spot check a few expenses
      if map[:advertising]
        assert_equal "100", read_field(doc, map[:advertising]), "Year #{year}: advertising mismatch"
      end

      if map[:repairs]
        assert_equal "1000", read_field(doc, map[:repairs]), "Year #{year}: repairs mismatch"
      end

      # Total expenses
      if map[:total_expenses]
        total_expected = EXPENSE_AMOUNTS.values.sum.to_s
        assert_equal total_expected, read_field(doc, map[:total_expenses]), "Year #{year}: total expenses mismatch"
      end
    end
  end
end
