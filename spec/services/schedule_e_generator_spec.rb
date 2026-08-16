require "rails_helper"
require "hexapdf"

RSpec.describe ScheduleEGenerator do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

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

  TEST_YEARS = [ 2025, 2022, 2021, 2018, 2015 ].freeze

  before do
    Charge.delete_all
    Expense.delete_all
    Receipt.delete_all
  end

  def create_data_for_year(year)
    date_in_year = Date.new(year, 6, 1)

    EXPENSE_AMOUNTS.each do |category, amount|
      create(:expense,
        property: property,
        category: category,
        amount: amount,
        expense_date: date_in_year,
        description: "Test #{category} #{year}"
      )
    end

    create(:receipt,
      tenancy: tenancy,
      received_on: date_in_year,
      amount_cents: (RENT_AMOUNT * 100).to_i,
      payment_method: "check",
      external_reference: "TEST-#{year}"
    )

    create(:receipt,
      tenancy: tenancy,
      amount_cents: (UTILITY_AMOUNT * 100).to_i,
      received_on: date_in_year,
      payment_method: "zelle"
    )
  end

  describe "PDF validity" do
    it "generates a valid PDF binary for representative years" do
      TEST_YEARS.each do |year|
        pdf_data = described_class.new(property, year).call
        expect(pdf_data).to be_present
        expect(pdf_data).to start_with("%PDF")
      end
    end

    it "raises TemplateMissingError if current year PDF is missing" do
      expect {
        described_class.new(property, 2026).call
      }.to raise_error(ScheduleEGenerator::TemplateMissingError)
    end

    it "raises TemplateMissingError if a very old year PDF is missing" do
      expect {
        described_class.new(property, 2010).call
      }.to raise_error(ScheduleEGenerator::TemplateMissingError)
    end
  end

  describe "field population" do
    def read_field(doc, name)
      return nil if name.nil?

      f = doc.acro_form.field_by_name(name)
      f&.field_value&.to_s
    end

    it "populates fields correctly for multiple years" do
      TEST_YEARS.each do |year|
        create_data_for_year(year)
        generator = described_class.new(property, year)
        pdf_data = generator.call
        doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))

        map = generator.send(:field_map)

        if map[:property_address]
          expect(read_field(doc, map[:property_address])).to eq(property.address)
        end

        if map[:rents_received]
          expected_rents = (RENT_AMOUNT + UTILITY_AMOUNT).to_s
          expect(read_field(doc, map[:rents_received])).to eq(expected_rents)
        end

        if map[:advertising]
          expect(read_field(doc, map[:advertising])).to eq("100")
        end

        if map[:repairs]
          expect(read_field(doc, map[:repairs])).to eq("1000")
        end

        if map[:total_expenses]
          total_expected = EXPENSE_AMOUNTS.values.sum.to_s
          expect(read_field(doc, map[:total_expenses])).to eq(total_expected)
        end

        Charge.delete_all
        Expense.delete_all
        Receipt.delete_all
      end
    end
  end

  describe "uncovered branch edge cases" do
    it "skips expenses with unknown categories" do
      generator = described_class.new(property, 2025)
      allow(generator).to receive(:expenses_by_category).and_return({ "unknown_category" => 100.0 })
      expect(generator.call).to be_present
    end

    it "handles net loss and covers net loss branches" do
      create(:expense, property: property, category: "repairs", amount: 1500, expense_date: Date.new(2025, 6, 1))
      create(:receipt, tenancy: tenancy, received_on: Date.new(2025, 6, 1), amount_cents: 100_000, payment_method: "check")

      generator = described_class.new(property, 2025)
      pdf_data = generator.call
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
      map = generator.send(:field_map)

      expect(read_field(doc, map[:net_loss])).to eq("500")
      expect(read_field(doc, map[:line_25])).to eq("500")
      expect(read_field(doc, map[:line_26])).to eq("-500")
    end

    it "skips setting field if the field is not present in the PDF form" do
      generator = described_class.new(property, 2025)
      allow_any_instance_of(HexaPDF::Type::AcroForm::Form).to receive(:field_by_name).and_return(nil)
      expect(generator.call).to be_present
    end

    it "covers the field_map fallback when year does not match any range" do
      generator = described_class.new(property, 2026)
      allow(generator).to receive(:template_path).and_return(Rails.root.join("app/assets/pdfs/f1040se--2025.pdf"))
      expect(generator.call).to be_present
    end

    it "maps different asset_types to correct schedule_e_type_codes" do
      generator = described_class.new(property, 2025)
      expect(generator.send(:schedule_e_type_code, "single_family")).to eq(1)
      expect(generator.send(:schedule_e_type_code, "multifamily")).to eq(2)
      expect(generator.send(:schedule_e_type_code, "commercial")).to eq(4)
      expect(generator.send(:schedule_e_type_code, "land")).to eq(5)
      expect(generator.send(:schedule_e_type_code, "mixed_use")).to eq(8)
      expect(generator.send(:schedule_e_type_code, "other")).to eq(8)
    end
  end

  def read_field(doc, name)
    return nil if name.nil?

    f = doc.acro_form.field_by_name(name)
    f&.field_value&.to_s
  end
end
