require "rails_helper"

RSpec.describe TaxReporting::ScheduleEQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(
      :tenancy,
      rentable_unit: unit,
      agreement_type: "month_to_month",
      commencement_date: Date.new(2025, 1, 1),
      termination_date: nil
    )
  end
  let!(:rent_term) do
    create(
      :rent_term,
      tenancy: tenancy,
      amount_cents: 200_000,
      effective_from: Date.new(2025, 1, 1),
      effective_until: nil
    )
  end
  let(:party) { create(:party, user: user) }
  let!(:tax_profile) do
    create(
      :property_tax_profile,
      property: property,
      tax_year: 2026,
      schedule_e_property_type: "multi_family_residence"
    )
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    create(:tenancy_party, tenancy: tenancy, party: party)
  end

  describe "Core Acceptance Scenarios" do
    it "unpaid rent charge affects receivable/accrual but contributes $0 to Schedule E rents received" do
      charge_res = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      expect(charge_res).to be_success

      result = described_class.call(property: property, tax_year: 2026)

      expect(result.rents_received_cents).to eq(0)
      expect(result.rents_received).to eq(BigDecimal("0.00"))
      expect(result.rents_received_drilldown).to be_empty

      # Verify GL accrual & receivable exist
      ar_acct = user.accounts.find_by!(key: "tenant_receivable")
      income_acct = user.accounts.find_by!(key: "rental_income")
      expect(Accounting::AccountBalanceQuery.call(account: ar_acct)).to eq(200_000)
      expect(Accounting::AccountBalanceQuery.call(account: income_acct)).to eq(200_000)
    end

    it "ordinary tenant receipt contributes to Schedule E rents received" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )

      rec_res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 75_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )
      expect(rec_res).to be_success

      result = described_class.call(property: property, tax_year: 2026)

      expect(result.rents_received_cents).to eq(75_000)
      expect(result.rents_received).to eq(BigDecimal("750.00"))
      expect(result.rents_received_drilldown.size).to eq(1)
      expect(result.rents_received_drilldown.first.amount_cents).to eq(75_000)
      expect(result.rents_received_drilldown.first.party).to eq(party)
    end

    it "prepayment in December 2026 reports in 2026 and not in 2027 under cash-received policy" do
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 200_000,
        received_on: Date.new(2026, 12, 28),
        payment_method: "zelle"
      )

      # 2026 report
      res2026 = described_class.call(property: property, tax_year: 2026)
      expect(res2026.rents_received_cents).to eq(200_000)

      # 2027 report with 2027 rent charge
      create(:property_tax_profile, property: property, tax_year: 2027, schedule_e_property_type: "multi_family_residence")
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2027, 1, 1)
      )

      res2027 = described_class.call(property: property, tax_year: 2027)
      expect(res2027.rents_received_cents).to eq(0)
    end

    it "overpayment reports full cash received without capping to charges" do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "rent",
        amount_cents: 200_000,
        charge_date: Date.new(2026, 1, 1)
      )
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 250_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(250_000)
    end

    it "receipt correction and voiding net correctly in rents received" do
      # Receipt $2,000 on Jan 5
      rec_res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 200_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )
      receipt = rec_res.value!.data[:receipt]

      # Correct to $2,100
      Receipts::CorrectService.call(
        receipt: receipt,
        amount_cents: 210_000,
        received_on: Date.new(2026, 1, 5),
        payment_method: "check"
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(210_000)
      expect(result.rents_received_drilldown.size).to eq(3) # original, reversal, replacement
    end

    it "refundable security deposit receipt contributes $0 to Schedule E rents received" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(0)
    end

    it "security deposit refund contributes $0 to Schedule E rents or expenses" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      SecurityDepositTransactions::RefundService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 10)
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(0)
      expect(result.total_expenses_cents).to eq(0)
      expect(result.review_items).to be_empty
    end

    it "security deposit application generates a structured tax review item" do
      deposit = create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "other",
        description: "Drywall damage",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 15)
      ).value!.data[:charge]

      SecurityDepositTransactions::ApplyService.call(
        security_deposit: deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 16)
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.rents_received_cents).to eq(0)
      expect(result.review_items.size).to eq(1)
      expect(result.review_items.first.amount_cents).to eq(50_000)
      expect(result.review_items.first.reason).to include("Security deposit applied")
    end
  end

  describe "Expenses Reporting" do
    it "maps every supported expense kind to its respective Schedule E line" do
      expense_kinds = %w[
        advertising
        auto_and_travel
        cleaning_and_maintenance
        commissions
        insurance
        legal_and_professional
        management
        mortgage_interest
        other_interest
        repairs
        supplies
        taxes
        utilities
        other
      ]

      expense_kinds.each_with_index do |kind, i|
        Expenses::CreateService.call(
          property: property,
          expense_kind: kind,
          paid_on: Date.new(2026, 1, i + 1),
          amount_cents: 10_000,
          description: "#{kind.titleize} expense"
        )
      end

      result = described_class.call(property: property, tax_year: 2026)

      expect(result.cents_for(:advertising)).to eq(10_000)
      expect(result.cents_for(:auto_and_travel)).to eq(10_000)
      expect(result.cents_for(:cleaning_and_maintenance)).to eq(10_000)
      expect(result.cents_for(:commissions)).to eq(10_000)
      expect(result.cents_for(:insurance)).to eq(10_000)
      expect(result.cents_for(:legal_and_professional)).to eq(10_000)
      expect(result.cents_for(:management)).to eq(10_000)
      expect(result.cents_for(:mortgage_interest)).to eq(10_000)
      expect(result.cents_for(:other_interest)).to eq(10_000)
      expect(result.cents_for(:repairs)).to eq(10_000)
      expect(result.cents_for(:supplies)).to eq(10_000)
      expect(result.cents_for(:taxes)).to eq(10_000)
      expect(result.cents_for(:utilities)).to eq(10_000)
      expect(result.cents_for(:other)).to eq(10_000)

      expect(result.total_expenses_cents).to eq(140_000)
      expect(result.other_expense_details.size).to eq(1)
      expect(result.other_expense_details.first.description).to eq("Other expense")
    end

    it "reversed expense nets to zero via double-entry postings" do
      exp_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "utilities",
        paid_on: Date.new(2026, 2, 1),
        amount_cents: 30_000
      )
      exp = exp_res.value!.data[:expense]
      Expenses::VoidService.call(expense: exp)

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.cents_for(:utilities)).to eq(0)
      expect(result.total_expenses_cents).to eq(0)
    end

    it "corrected expense nets to replacement amount" do
      exp_res = Expenses::CreateService.call(
        property: property,
        expense_kind: "utilities",
        paid_on: Date.new(2026, 2, 1),
        amount_cents: 30_000
      )
      exp = exp_res.value!.data[:expense]

      Expenses::CorrectService.call(
        expense: exp,
        amount_cents: 35_000
      )

      result = described_class.call(property: property, tax_year: 2026)
      expect(result.cents_for(:utilities)).to eq(35_000)
      expect(result.total_expenses_cents).to eq(35_000)
    end
  end

  describe "Multi-Property & Year Isolation" do
    it "isolates transactions between properties" do
      prop2 = create(:property, user: user)
      unit2 = create(:rentable_unit, property: prop2)
      tenancy2 = create(:tenancy, rentable_unit: unit2)
      create(:tenancy_party, tenancy: tenancy2, party: party)
      create(:property_tax_profile, property: prop2, tax_year: 2026, schedule_e_property_type: "single_family_residence")

      # Property 1 activity
      Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount_cents: 200_000, received_on: Date.new(2026, 1, 5), payment_method: "check")
      Expenses::CreateService.call(property: property, expense_kind: "utilities", paid_on: Date.new(2026, 1, 10), amount_cents: 30_000)

      # Property 2 activity
      Receipts::CreateService.call(tenancy: tenancy2, payer_party: party, amount_cents: 150_000, received_on: Date.new(2026, 1, 5), payment_method: "check")
      Expenses::CreateService.call(property: prop2, expense_kind: "utilities", paid_on: Date.new(2026, 1, 10), amount_cents: 20_000)

      res1 = described_class.call(property: property, tax_year: 2026)
      expect(res1.rents_received_cents).to eq(200_000)
      expect(res1.cents_for(:utilities)).to eq(30_000)

      res2 = described_class.call(property: prop2, tax_year: 2026)
      expect(res2.rents_received_cents).to eq(150_000)
      expect(res2.cents_for(:utilities)).to eq(20_000)
    end

    it "returns :tax_profile_required status when profile is missing" do
      result = described_class.call(property: property, tax_year: 2024)
      expect(result.status).to eq(:tax_profile_required)
      expect(result.tax_profile).to be_nil
      expect(result.tax_profile_configured?).to be false
    end

    it "handles nil property safely" do
      result = described_class.call(property: nil)
      expect(result.status).to eq(:tax_profile_required)
      expect(result.rents_received_cents).to eq(0)
    end
  end
end
