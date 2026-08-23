require "rails_helper"
require "hexapdf"

RSpec.describe ScheduleEGenerator do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(
      :tenancy,
      rentable_unit: unit,
      agreement_type: "month_to_month",
      commencement_date: Date.new(2010, 1, 1),
      termination_date: nil
    )
  end

  EXPENSE_AMOUNTS = {
    "advertising"                       => 100,
    "auto_and_travel"                   => 200,
    "cleaning_and_maintenance"          => 300,
    "commissions"                       => 400,
    "insurance"                         => 500,
    "legal_and_professional"            => 600,
    "management"                        => 700,
    "mortgage_interest"                 => 800,
    "other_interest"                    => 900,
    "repairs"                           => 1000,
    "supplies"                          => 1100,
    "taxes"                             => 1200,
    "utilities"                         => 1300,
    "other"                             => 1500
  }.freeze

  RENT_AMOUNT    = 12_000
  UTILITY_AMOUNT = 250

  let(:party) { create(:party, user: user) }
  let!(:rent_term) { create(:rent_term, tenancy: tenancy, effective_from: Date.new(2010, 1, 1), effective_until: nil) }

  ALL_SUPPORTED_YEARS = (2011..2025).to_a.freeze

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    create(:tenancy_party, tenancy: tenancy, party: party)
  end

  def create_data_for_year(year, property_type: "multi_family_residence", other_desc: nil)
    date_in_year = Date.new(year, 6, 1)

    create(
      :property_tax_profile,
      property: property,
      tax_year: year,
      schedule_e_property_type: property_type,
      other_description: other_desc
    )

    EXPENSE_AMOUNTS.each do |kind, amount|
      Expenses::CreateService.call(
        property: property,
        expense_kind: kind,
        amount_cents: amount * 100,
        paid_on: date_in_year,
        description: "Test #{kind} #{year}"
      )
    end

    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      received_on: date_in_year,
      amount_cents: (RENT_AMOUNT * 100).to_i,
      payment_method: "check",
      external_reference: "TEST-#{year}"
    )

    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: (UTILITY_AMOUNT * 100).to_i,
      received_on: date_in_year,
      payment_method: "zelle"
    )
  end

  def clean_database_for_next_year
    Posting.delete_all
    JournalEntry.delete_all
    Charge.delete_all
    Expense.delete_all
    Receipt.delete_all
    PropertyTaxProfile.delete_all
  end

  def read_field(doc, name)
    return nil if name.nil?

    f = doc.acro_form.field_by_name(name)
    f&.field_value&.to_s
  end

  describe "PDF validity and tax profile requirements" do
    it "raises TaxProfileRequiredError when no tax profile is configured for the year" do
      expect {
        described_class.new(property, 2025).call
      }.to raise_error(ScheduleEGenerator::TaxProfileRequiredError, /Tax classification must be configured/)
    end

    it "raises TaxReviewRequiredError when unresolved review items exist" do
      create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")

      # Create an unmapped account posting that generates a review item
      unmapped_account = user.accounts.create!(
        name: "Capital Improvements",
        key: "expense_capital_improvements",
        account_type: "expense",
        active: true
      )
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 4, 1),
        description: "New roof installation",
        event_type: "expense_posted"
      )
      create(
        :posting,
        journal_entry: entry,
        account: unmapped_account,
        property: property,
        amount_cents: 800_000
      )

      expect {
        described_class.new(property, 2025).call
      }.to raise_error(ScheduleEGenerator::TaxReviewRequiredError, /Schedule E PDF cannot be generated while \d+ unresolved review item\(s\) exist/)
    end

    it "generates a valid PDF binary for all 15 supported template years (2011-2025)" do
      ALL_SUPPORTED_YEARS.each do |year|
        create_data_for_year(year)
        pdf_data = described_class.new(property, year).call
        expect(pdf_data).to be_present
        expect(pdf_data).to start_with("%PDF")
        clean_database_for_next_year
      end
    end

    it "raises TemplateMissingError if current year PDF template is missing" do
      create(:property_tax_profile, property: property, tax_year: 2026, schedule_e_property_type: "single_family_residence")
      expect {
        described_class.new(property, 2026).call
      }.to raise_error(ScheduleEGenerator::TemplateMissingError)
    end

    it "raises TemplateMissingError if a very old year PDF is missing" do
      create(:property_tax_profile, property: property, tax_year: 2010, schedule_e_property_type: "single_family_residence")
      expect {
        described_class.new(property, 2010).call
      }.to raise_error(ScheduleEGenerator::TemplateMissingError)
    end
  end

  describe "field population and IRS layout round-trip verification" do
    it "maps every expense to a distinct existing AcroForm field and round-trips values for all 15 years" do
      ALL_SUPPORTED_YEARS.each do |year|
        create_data_for_year(year)
        generator = described_class.new(property, year)
        pdf_data = generator.call
        doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))

        map = generator.send(:field_map)

        # 1. Verify property address & type
        expect(read_field(doc, map[:property_address])).to eq(property.address)
        expect(read_field(doc, map[:property_type])).to eq("2")

        # 2. Untracked fields: fair rental days and personal use days must remain blank
        expect(read_field(doc, map[:fair_rental_days])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:personal_use_days])).to be_nil.or(eq(""))

        # 3. Income
        expected_rents = (RENT_AMOUNT + UTILITY_AMOUNT).to_s
        expect(read_field(doc, map[:rents_received])).to eq(expected_rents)

        # 4. Expenses: verify every single expense category is populated distinctly
        EXPENSE_AMOUNTS.each do |cat, amount|
          field_key = ScheduleEGenerator::CATEGORY_TO_FIELD[cat]
          field_name = map[field_key]
          expect(field_name).to be_present, "Expected field_map to have key #{field_key} for #{year}"
          expect(read_field(doc, field_name)).to eq(amount.to_s)
        end

        # Line 19 description is populated
        expect(read_field(doc, map[:line_19_description])).to eq("Test other #{year}")

        # 5. Dependent totals & summary lines: Line 18 depreciation is omitted and summary lines (23a-26)
        # represent portfolio-wide totals on IRS Form 1040 Schedule E, so all summary totals (Lines 20-26)
        # must remain blank on the single-property draft worksheet PDF.
        expect(read_field(doc, map[:depreciation_expense])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:total_expenses])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:net_income])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:net_loss])).to be_nil.or(eq(""))

        # 6. Line 23a-23e summary fields semantics (all blank on single-property worksheet)
        expect(read_field(doc, map[:line_23a])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:line_23b])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:line_23c])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:line_23d])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:line_23e])).to be_nil.or(eq(""))
        # 24, 25, 26: final dependent totals (blank)
        expect(read_field(doc, map[:line_24])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:line_25])).to be_nil.or(eq(""))
        expect(read_field(doc, map[:line_26])).to be_nil.or(eq(""))

        clean_database_for_next_year
      end
    end

    it "populates Line 1b Other Description when property type is 8 (other)" do
      [ 2015, 2018, 2022, 2025 ].each do |year|
        create_data_for_year(year, property_type: "other", other_desc: "Commercial boat slip")
        generator = described_class.new(property, year)
        pdf_data = generator.call
        doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
        map = generator.send(:field_map)

        expect(read_field(doc, map[:property_type])).to eq("8")
        expect(read_field(doc, map[:other_type_description])).to eq("Commercial boat slip")
        clean_database_for_next_year
      end
    end
  end

  describe "uncovered branch edge cases and loss handling" do
    before do
      create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")
    end

    it "reports template_available? correctly for supported vs unsupported years" do
      expect(described_class.template_available?(2025)).to be true
      expect(described_class.template_available?(2015)).to be true
      expect(described_class.template_available?(2026)).to be false
      expect(described_class.template_available?(2000)).to be false
    end

    it "leaves summary Lines 23a–26 blank across multiple properties to avoid misrepresenting property subtotals as portfolio totals" do
      prop_b = create(:property, user: user, address: "456 Oak Avenue")
      unit_b = create(:rentable_unit, property: prop_b)
      tenancy_b = create(:tenancy, rentable_unit: unit_b)
      create(:tenancy_party, tenancy: tenancy_b, party: party)
      create(:property_tax_profile, property: prop_b, tax_year: 2025, schedule_e_property_type: "single_family_residence")

      # Property A: Rents $20,000, Mortgage $5,000
      Receipts::CreateService.call(tenancy: tenancy, payer_party: party, received_on: Date.new(2025, 1, 5), amount_cents: 2_000_000, payment_method: "check")
      Expenses::CreateService.call(property: property, expense_kind: "mortgage_interest", amount_cents: 500_000, paid_on: Date.new(2025, 2, 1))

      # Property B: Rents $15,000, Mortgage $3,000
      Receipts::CreateService.call(tenancy: tenancy_b, payer_party: party, received_on: Date.new(2025, 1, 5), amount_cents: 1_500_000, payment_method: "check")
      Expenses::CreateService.call(property: prop_b, expense_kind: "mortgage_interest", amount_cents: 300_000, paid_on: Date.new(2025, 2, 1))

      # Worksheet for Property A
      gen_a = described_class.new(property, 2025)
      doc_a = HexaPDF::Document.new(io: StringIO.new(gen_a.call))
      map_a = gen_a.send(:field_map)
      expect(read_field(doc_a, map_a[:rents_received])).to eq("20000")
      expect(read_field(doc_a, map_a[:mortgage_interest])).to eq("5000")
      expect(read_field(doc_a, map_a[:line_23a])).to be_nil.or(eq(""))
      expect(read_field(doc_a, map_a[:line_23c])).to be_nil.or(eq(""))

      # Worksheet for Property B
      gen_b = described_class.new(prop_b, 2025)
      doc_b = HexaPDF::Document.new(io: StringIO.new(gen_b.call))
      map_b = gen_b.send(:field_map)
      expect(read_field(doc_b, map_b[:rents_received])).to eq("15000")
      expect(read_field(doc_b, map_b[:mortgage_interest])).to eq("3000")
      expect(read_field(doc_b, map_b[:line_23a])).to be_nil.or(eq(""))
      expect(read_field(doc_b, map_b[:line_23c])).to be_nil.or(eq(""))
    end

    it "paginates Line 19 supplemental statement across multiple pages when there are 50 entries and reconciles total with Line 19" do
      total_expected_cents = 0
      50.times do |i|
        amt_cents = 10_000 + (i * 100)
        total_expected_cents += amt_cents
        Expenses::CreateService.call(
          property: property,
          expense_kind: "other",
          amount_cents: amt_cents,
          paid_on: Date.new(2025, (i % 12) + 1, (i % 28) + 1),
          description: "Other expense item #{i + 1} with a descriptive detail note"
        )
      end

      generator = described_class.new(property, 2025)
      pdf_data = generator.call
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
      map = generator.send(:field_map)

      expected_line_19 = BigDecimal(total_expected_cents.to_s) / 100
      expected_rounded_str = BigDecimal(expected_line_19.to_s).round(0, BigDecimal::ROUND_HALF_UP).to_i.to_s

      # Form page assertions
      expect(read_field(doc, map[:line_19_description])).to eq("See attached statement")
      expect(read_field(doc, map[:other])).to eq(expected_rounded_str)

      # 2 form pages + 2 supplemental statement pages (25 items per page) = 4 total pages
      expect(doc.pages.count).to eq(4)
    end

    it "formats Line 19 description as 'See attached statement' and appends supplemental statement page when descriptions exceed 36 chars" do
      Expenses::CreateService.call(
        property: property,
        expense_kind: "other",
        amount_cents: 10_000,
        paid_on: Date.new(2025, 3, 1),
        description: "Very long descriptive text for other expense number one"
      )
      Expenses::CreateService.call(
        property: property,
        expense_kind: "other",
        amount_cents: 15_000,
        paid_on: Date.new(2025, 4, 1),
        description: "Another very long descriptive text for other expense"
      )

      generator = described_class.new(property, 2025)
      pdf_data = generator.call
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
      map = generator.send(:field_map)

      expect(read_field(doc, map[:line_19_description])).to eq("See attached statement")
      expect(read_field(doc, map[:other])).to eq("250")
      expect(doc.pages.count).to eq(3)
    end

    it "applies whole-dollar nearest-dollar (half-up) rounding on aggregated line totals (.49, .50, .99)" do
      # 1. $100.49 -> rounds down to 100
      Expenses::CreateService.call(
        property: property,
        expense_kind: "advertising",
        amount_cents: 10_049,
        paid_on: Date.new(2025, 3, 1)
      )
      # 2. $100.50 -> rounds up to 101
      Expenses::CreateService.call(
        property: property,
        expense_kind: "supplies",
        amount_cents: 10_050,
        paid_on: Date.new(2025, 3, 1)
      )
      # 3. $100.99 -> rounds up to 101
      Expenses::CreateService.call(
        property: property,
        expense_kind: "repairs",
        amount_cents: 10_099,
        paid_on: Date.new(2025, 3, 1)
      )

      generator = described_class.new(property, 2025)
      pdf_data = generator.call
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
      map = generator.send(:field_map)

      expect(read_field(doc, map[:advertising])).to eq("100")
      expect(read_field(doc, map[:supplies])).to eq("101")
      expect(read_field(doc, map[:repairs])).to eq("101")
    end

    it "skips expenses with unknown categories" do
      generator = described_class.new(property, 2025)
      allow(generator).to receive(:expenses_by_category).and_return({ "unknown_category" => 100.0 })
      expect(generator.call).to be_present
    end

    it "handles net loss by leaving dependent fields (Line 21, 22, 24, 25, 26) blank on worksheet" do
      Expenses::CreateService.call(property: property, expense_kind: "repairs", amount_cents: 150_000, paid_on: Date.new(2025, 6, 1))
      Receipts::CreateService.call(tenancy: tenancy, payer_party: party, received_on: Date.new(2025, 6, 1), amount_cents: 100_000, payment_method: "check")

      generator = described_class.new(property, 2025)
      pdf_data = generator.call
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
      map = generator.send(:field_map)

      expect(read_field(doc, map[:rents_received])).to eq("1000")
      expect(read_field(doc, map[:repairs])).to eq("1500")
      expect(read_field(doc, map[:net_income])).to be_nil.or(eq(""))
      expect(read_field(doc, map[:net_loss])).to be_nil.or(eq(""))
      expect(read_field(doc, map[:line_24])).to be_nil.or(eq(""))
      expect(read_field(doc, map[:line_25])).to be_nil.or(eq(""))
      expect(read_field(doc, map[:line_26])).to be_nil.or(eq(""))
    end

    it "skips setting field if the field is not present in the PDF form" do
      generator = described_class.new(property, 2025)
      allow_any_instance_of(HexaPDF::Type::AcroForm::Form).to receive(:field_by_name).and_return(nil)
      expect(generator.call).to be_present
    end

    it "raises TaxReviewRequiredError when an unresolved review item exists, but succeeds once resolved" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2025, 1, 1)
      )
      charge = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "other",
        description: "Drywall repair",
        amount_cents: 50_000,
        charge_date: Date.new(2025, 6, 1)
      ).value!.data[:charge]
      apply_res = SecurityDepositTransactions::ApplyService.call(
        security_deposit: deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2025, 6, 15)
      )
      entry = apply_res.value!.data[:journal_entry]

      # 1. Unresolved: fails with TaxReviewRequiredError
      expect {
        described_class.new(property, 2025).call
      }.to raise_error(ScheduleEGenerator::TaxReviewRequiredError, /unresolved review item/)

      # 2. Resolved with 'include_in_rents': unblocks PDF generation and populates Line 3
      resolution = create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry,
        tax_year: 2025,
        treatment: "include_in_rents"
      )

      pdf_data = described_class.new(property, 2025).call
      expect(pdf_data).to be_present
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
      generator = described_class.new(property, 2025)
      map = generator.send(:field_map)
      expect(read_field(doc, map[:rents_received])).to eq("500")

      # 3. Resolved with 'exclude': unblocks PDF generation and Line 3 has $0
      resolution.update!(treatment: "exclude")
      pdf_data_excluded = described_class.new(property, 2025).call
      doc_excluded = HexaPDF::Document.new(io: StringIO.new(pdf_data_excluded))
      expect(read_field(doc_excluded, map[:rents_received])).to eq("0")
    end

    it "blocks PDF export for unmapped expense review items until mapped to a Schedule E category or excluded" do
      unmapped_account = user.accounts.create!(name: "Custom Roof", key: "expense_custom_roof", account_type: "expense")
      expense = create(:expense, property: property, expense_kind: "other", amount_cents: 800_000)
      entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 4, 1),
        description: "New roof installation",
        event_type: "expense_posted",
        source: expense
      )
      create(:posting, journal_entry: entry, account: unmapped_account, property: property, amount_cents: 800_000)

      # 1. Unresolved: raises TaxReviewRequiredError
      expect {
        described_class.new(property, 2025).call
      }.to raise_error(ScheduleEGenerator::TaxReviewRequiredError, /unresolved review item/)

      # 2. Resolved with 'map_to_schedule_e_category' -> unblocks and populates Repairs (Line 14)
      resolution = create(
        :property_tax_review_resolution,
        property: property,
        journal_entry: entry,
        tax_year: 2025,
        treatment: "map_to_schedule_e_category",
        schedule_e_category: "repairs"
      )

      pdf_data = described_class.new(property, 2025).call
      expect(pdf_data).to be_present
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
      generator = described_class.new(property, 2025)
      map = generator.send(:field_map)
      expect(read_field(doc, map[:repairs])).to eq("8000")

      # 3. Resolved with 'exclude' -> unblocks and Repairs is empty
      resolution.update!(treatment: "exclude", schedule_e_category: nil)
      pdf_data_excluded = described_class.new(property, 2025).call
      doc_excluded = HexaPDF::Document.new(io: StringIO.new(pdf_data_excluded))
      expect(read_field(doc_excluded, map[:repairs])).to be_nil.or(eq("0")).or(eq(""))
    end

    it "covers the field_map fallback when year does not match any range" do
      create(:property_tax_profile, property: property, tax_year: 2010, schedule_e_property_type: "single_family_residence")
      generator = described_class.new(property, 2010)
      expect(generator.send(:field_map)).to eq(ScheduleEGenerator::MAP_2023_PRESENT)

      # set_field with an unmapped key
      dummy_doc = HexaPDF::Document.new
      form = dummy_doc.acro_form(create: true)
      expect(generator.send(:set_field, form, :completely_unknown_key, "val")).to be_nil
    end

    it "populates Line 19 description and supporting details for prior-year-expense current-year-reversal" do
      # 2024: Other expense of $100 with long description
      exp = create(:expense, property: property, expense_kind: "other", amount_cents: 10_000, description: "Emergency structural chimney and masonry assessment")
      entry_2024 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2024, 12, 15),
        description: "Emergency structural chimney and masonry assessment",
        event_type: "expense_posted",
        source: exp
      )
      create(:posting, journal_entry: entry_2024, account: user.accounts.find_by!(key: "expense_other"), property: property, amount_cents: 10_000)

      # 2025: Reversal of 2024 expense in 2025
      rev_2025 = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 1, 10),
        description: "Emergency structural chimney and masonry assessment",
        event_type: "reversal",
        reversal_of: entry_2024,
        source: exp
      )
      create(:posting, journal_entry: rev_2025, account: user.accounts.find_by!(key: "expense_other"), property: property, amount_cents: -10_000)

      pdf_data = described_class.new(property, 2025).call
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_data))
      generator = described_class.new(property, 2025)
      map = generator.send(:field_map)

      # Negative amount on Line 19
      expect(read_field(doc, map[:other])).to eq("-100")
      # Long description triggers "See attached statement"
      expect(read_field(doc, map[:line_19_description])).to eq("See attached statement")
      # Supplemental statement page appended (2 form pages + 1 statement page = 3 total pages)
      expect(doc.pages.count).to eq(3)
    end
  end
end
