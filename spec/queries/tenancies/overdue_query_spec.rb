require "rails_helper"

RSpec.describe Tenancies::OverdueQuery do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property, name: "Unit 1") }
  let(:tenancy) do
    create(
      :tenancy,
      rentable_unit: unit,
      agreement_type: "month_to_month",
      commencement_date: Date.current - 1.year,
      termination_date: nil,
      late_period_days: 5
    )
  end

  before { Accounting::ChartOfAccounts.ensure_for(user) }

  def post_charge(amount_cents:, due_on:, target: tenancy)
    result = Charges::CreateService.call(
      tenancy: target,
      charge_kind: "other",
      amount_cents: amount_cents,
      charge_date: due_on,
      due_on: due_on,
      description: "Charge due #{due_on}"
    )
    raise result.failure.error unless result.success?

    result.value!.data[:charge]
  end

  def balances_for(*targets)
    Accounting::TenancyBalancesQuery.call(tenancies: targets)
  end

  def overdue_for(*targets)
    described_class.call(tenancies: targets, balances: balances_for(*targets))
  end

  describe ".call" do
    it "returns no overdue money for a charge due today" do
      post_charge(amount_cents: 120_000, due_on: Date.current)

      expect(overdue_for(tenancy)).to eq(tenancy.id => 0)
    end

    it "treats the last day of the grace period as still not due" do
      post_charge(amount_cents: 120_000, due_on: Date.current - 5.days)

      expect(overdue_for(tenancy)).to eq(tenancy.id => 0)
    end

    it "reports the charge as overdue the day after the grace period ends" do
      post_charge(amount_cents: 120_000, due_on: Date.current - 6.days)

      expect(overdue_for(tenancy)).to eq(tenancy.id => 120_000)
    end

    it "reports only the portion of the balance beyond the charges not yet due" do
      post_charge(amount_cents: 50_000, due_on: Date.current - 40.days)
      post_charge(amount_cents: 120_000, due_on: Date.current)

      expect(overdue_for(tenancy)).to eq(tenancy.id => 50_000)
    end

    it "does not let a future-dated charge shield money that is already late" do
      # The balance excludes the future charge's journal entry, so the shield
      # must exclude the charge itself or the overdue amount disappears.
      post_charge(amount_cents: 50_000, due_on: Date.current - 40.days)
      post_charge(amount_cents: 120_000, due_on: Date.current + 10.days)

      expect(balances_for(tenancy)).to eq(tenancy.id => 50_000)
      expect(overdue_for(tenancy)).to eq(tenancy.id => 50_000)
    end

    it "still shields a charge dated today whose grace period has not passed" do
      post_charge(amount_cents: 50_000, due_on: Date.current - 40.days)
      post_charge(amount_cents: 120_000, due_on: Date.current)

      expect(overdue_for(tenancy)).to eq(tenancy.id => 50_000)
    end

    it "applies credits to the oldest charge first, clearing the overdue amount" do
      post_charge(amount_cents: 50_000, due_on: Date.current - 40.days)
      post_charge(amount_cents: 120_000, due_on: Date.current)
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: create(:party, user: user),
        amount_cents: 50_000,
        received_on: Date.current,
        payment_method: "check"
      )

      expect(overdue_for(tenancy)).to eq(tenancy.id => 0)
    end

    it "honours each tenancy's own grace period in a single pass" do
      strict_unit = create(:rentable_unit, property: property, name: "Unit 2")
      strict_tenancy = create(
        :tenancy,
        rentable_unit: strict_unit,
        agreement_type: "month_to_month",
        commencement_date: Date.current - 1.year,
        termination_date: nil,
        late_period_days: 0
      )
      post_charge(amount_cents: 90_000, due_on: Date.current - 3.days)
      post_charge(amount_cents: 90_000, due_on: Date.current - 3.days, target: strict_tenancy)

      expect(overdue_for(tenancy, strict_tenancy)).to eq(
        tenancy.id => 0,
        strict_tenancy.id => 90_000
      )
    end

    it "ignores charges that are not posted" do
      post_charge(amount_cents: 50_000, due_on: Date.current - 40.days)
      create(:charge, tenancy: tenancy, amount_cents: 500_000, charge_date: Date.current, due_on: Date.current + 10.days)

      expect(overdue_for(tenancy)).to eq(tenancy.id => 50_000)
    end

    it "ignores voided charges" do
      post_charge(amount_cents: 50_000, due_on: Date.current - 40.days)
      not_yet_due = post_charge(amount_cents: 120_000, due_on: Date.current)
      Charges::VoidService.call(charge: not_yet_due, reason: "Billed in error")

      expect(overdue_for(tenancy)).to eq(tenancy.id => 50_000)
    end

    it "reports zero for a tenancy holding a credit" do
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: create(:party, user: user),
        amount_cents: 75_000,
        received_on: Date.current,
        payment_method: "cash"
      )

      expect(overdue_for(tenancy)).to eq(tenancy.id => 0)
    end

    it "reports zero for a tenancy with no balance entry at all" do
      expect(described_class.call(tenancies: [ tenancy ], balances: nil)).to eq(tenancy.id => 0)
    end

    it "returns an empty hash when given no tenancies" do
      expect(described_class.call(tenancies: [], balances: {})).to eq({})
      expect(described_class.call(tenancies: nil, balances: {})).to eq({})
    end

    it "accepts an explicit as_of date" do
      post_charge(amount_cents: 120_000, due_on: Date.current - 6.days)

      expect(
        described_class.call(
          tenancies: [ tenancy ],
          balances: balances_for(tenancy),
          as_of: Date.current - 6.days
        )
      ).to eq(tenancy.id => 0)
    end

    it "reads the charges in one grouped query regardless of tenancy count" do
      second_unit = create(:rentable_unit, property: property, name: "Unit 3")
      second_tenancy = create(
        :tenancy,
        rentable_unit: second_unit,
        agreement_type: "month_to_month",
        commencement_date: Date.current - 1.year,
        termination_date: nil
      )
      post_charge(amount_cents: 10_000, due_on: Date.current)
      post_charge(amount_cents: 10_000, due_on: Date.current, target: second_tenancy)

      balances = balances_for(tenancy, second_tenancy)
      charge_queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        charge_queries += 1 if payload[:sql].to_s.include?('FROM "charges"')
      end
      begin
        described_class.call(tenancies: [ tenancy, second_tenancy ], balances: balances)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(charge_queries).to eq(1)
    end
  end
end
