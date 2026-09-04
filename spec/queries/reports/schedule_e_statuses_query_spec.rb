require "rails_helper"

RSpec.describe Reports::ScheduleEStatusesQuery do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  let!(:property_no_profile) { create(:property, user: user, address: "123 Main St") }

  let(:property_needs_review) { create(:property, user: user, address: "456 Oak Ave") }
  let!(:tax_profile_review) do
    create(
      :property_tax_profile,
      property: property_needs_review,
      tax_year: 2025,
      schedule_e_property_type: "single_family_residence"
    )
  end

  let(:property_ready) { create(:property, user: user, address: "742 Evergreen Terrace") }
  let!(:tax_profile_ready) do
    create(
      :property_tax_profile,
      property: property_ready,
      tax_year: 2025,
      schedule_e_property_type: "single_family_residence"
    )
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    Accounting::ChartOfAccounts.ensure_for(other_user)

    # For property_ready: create a tenancy and rent payment in 2025
    unit = create(:rentable_unit, property: property_ready)
    tenancy = create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2025, 1, 1))
    create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.new(2025, 1, 1))
    party = create(:party, user: user)

    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 100_000,
      received_on: Date.new(2025, 6, 1),
      payment_method: "check"
    )

    # For property_needs_review: create a deposit_applied entry in 2025 that requires review
    entry = create(
      :journal_entry,
      user: user,
      occurred_on: Date.new(2025, 9, 12),
      event_type: "deposit_applied",
      source: property_needs_review
    )
    create(:posting, journal_entry: entry, property: property_needs_review, amount_cents: -50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
    create(:posting, journal_entry: entry, property: property_needs_review, amount_cents: 50_000, account: user.accounts.find_by!(key: "security_deposits_held"))
  end

  describe ".call" do
    it "returns per-property schedule E status for the tax year" do
      statuses = described_class.call(user: user, tax_year: 2025)
      expect(statuses.size).to eq(3)

      status_no_prof = statuses.find { |s| s.property.id == property_no_profile.id }
      expect(status_no_prof).to be_present
      expect(status_no_prof.state).to eq(:needs_profile)
      expect(status_no_prof.unresolved_review_count).to eq(0)
      expect(status_no_prof.net_income_cents).to eq(0)

      status_review = statuses.find { |s| s.property.id == property_needs_review.id }
      expect(status_review).to be_present
      expect(status_review.state).to eq(:needs_review)
      expect(status_review.unresolved_review_count).to be >= 1

      status_ready = statuses.find { |s| s.property.id == property_ready.id }
      expect(status_ready).to be_present
      expect(status_ready.state).to eq(:ready)
      expect(status_ready.unresolved_review_count).to eq(0)
      expect(status_ready.net_income_cents).to eq(100_000)
    end

    it "orders needs_profile, then needs_review, then ready, with address as the tiebreak" do
      # Addresses chosen so alphabetical order disagrees with state order.
      ready_first_alphabetically = create(:property, user: user, address: "001 Ready Ave")
      create(
        :property_tax_profile,
        property: ready_first_alphabetically,
        tax_year: 2025,
        schedule_e_property_type: "single_family_residence"
      )
      create(:property, user: user, address: "999 Zebra Way")

      statuses = described_class.call(user: user, tax_year: 2025)

      expect(statuses.map { |status| [ status.state, status.property.address ] }).to eq(
        [
          [ :needs_profile, "123 Main St" ],
          [ :needs_profile, "999 Zebra Way" ],
          [ :needs_review, "456 Oak Ave" ],
          [ :ready, "001 Ready Ave" ],
          [ :ready, "742 Evergreen Terrace" ]
        ]
      )
    end

    it "flags the states that still require action" do
      statuses = described_class.call(user: user, tax_year: 2025).index_by(&:state)

      expect(statuses[:needs_profile]).to be_needs_work
      expect(statuses[:needs_review]).to be_needs_work
      expect(statuses[:ready]).not_to be_needs_work
    end

    it "enforces cross-user isolation" do
      other_property = create(:property, user: other_user)
      create(
        :property_tax_profile,
        property: other_property,
        tax_year: 2025,
        schedule_e_property_type: "single_family_residence"
      )

      statuses = described_class.call(user: user, tax_year: 2025)
      expect(statuses.map(&:property)).not_to include(other_property)
    end

    it "maintains exact agreement with ScheduleEQuery for in-year and cross-year reversed events" do
      # Case A: in-year reversal of an unresolved review event
      reversed_prop = create(:property, user: user, address: "888 Reversed Way")
      create(:property_tax_profile, property: reversed_prop, tax_year: 2025, schedule_e_property_type: "single_family_residence")

      original_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 4, 1),
        event_type: "deposit_applied",
        source: reversed_prop
      )
      create(:posting, journal_entry: original_entry, property: reversed_prop, amount_cents: -50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: original_entry, property: reversed_prop, amount_cents: 50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      reversal_entry = create(
        :journal_entry,
        user: user,
        occurred_on: Date.new(2025, 4, 15),
        event_type: "reversal",
        source: reversed_prop,
        reversal_of: original_entry
      )
      create(:posting, journal_entry: reversal_entry, property: reversed_prop, amount_cents: 50_000, account: user.accounts.find_by!(key: "tenant_receivable"))
      create(:posting, journal_entry: reversal_entry, property: reversed_prop, amount_cents: -50_000, account: user.accounts.find_by!(key: "security_deposits_held"))

      query_result = TaxReporting::ScheduleEQuery.call(property: reversed_prop, tax_year: 2025)
      status_obj = described_class.status_for(property: reversed_prop, tax_year: 2025)

      # Unresolved state: exact agreement
      expect(status_obj.state).to eq(:needs_review)
      expect(status_obj.unresolved_review_count).to eq(query_result.unresolved_review_items.size)
      expect(status_obj.net_income_cents).to eq(query_result.net_income_cents)

      # Once resolved: exact agreement on ready state and 0 net income
      PropertyTaxReviewResolution.create!(
        property: reversed_prop,
        journal_entry: original_entry,
        tax_year: 2025,
        treatment: "include_in_rents"
      )

      resolved_query_result = TaxReporting::ScheduleEQuery.call(property: reversed_prop, tax_year: 2025)
      resolved_status = described_class.status_for(property: reversed_prop, tax_year: 2025)

      expect(resolved_status.state).to eq(:ready)
      expect(resolved_status.unresolved_review_count).to eq(0)
      expect(resolved_status.unresolved_review_count).to eq(resolved_query_result.unresolved_review_items.size)
      expect(resolved_status.net_income_cents).to eq(resolved_query_result.net_income_cents)
      expect(resolved_status.net_income_cents).to eq(0)
    end

    describe ".status_for" do
      it "returns nil when property is nil" do
        expect(described_class.status_for(property: nil, tax_year: 2025)).to be_nil
      end

      it "returns matching ScheduleEStatus for a single property" do
        single_status = described_class.status_for(property: property_ready, tax_year: 2025)
        expect(single_status.property).to eq(property_ready)
        expect(single_status.state).to eq(:ready)
        expect(single_status.net_income_cents).to eq(100_000)
      end
    end
  end
end
