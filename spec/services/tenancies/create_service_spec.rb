require "rails_helper"

RSpec.describe Tenancies::CreateService do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party1) { create(:party, user: user, display_name: "Alice") }
  let(:party2) { create(:party, user: user, display_name: "Bob") }

  describe ".call" do
    context "with valid parameters" do
      let(:params) do
        {
          rentable_unit_id: unit.id,
          agreement_type: "fixed_term",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: Date.new(2025, 12, 31),
          late_period_days: 5,
          party_ids: [ party1.id, party2.id ],
          rent_amount: "2150.00",
          due_day: 1,
          frequency: "monthly"
        }
      end

      it "atomically creates tenancy, tenancy_parties, and initial rent_term" do
        result = nil
        expect {
          result = described_class.call(user: user, params: params)
        }.to change(Tenancy, :count).by(1)
         .and change(TenancyParty, :count).by(2)
         .and change(RentTerm, :count).by(1)

        expect(result).to be_success
        tenancy = result.value!.data[:tenancy]
        expect(tenancy.rentable_unit).to eq(unit)
        expect(tenancy.parties).to contain_exactly(party1, party2)

        expect(tenancy.tenancy_parties.pluck(:effective_until)).to contain_exactly(Date.new(2025, 12, 31), Date.new(2025, 12, 31))

        rent_term = tenancy.rent_terms.first
        expect(rent_term.amount_cents).to eq(215_000)
        expect(rent_term.due_day).to eq(1)
        expect(rent_term.frequency).to eq("monthly")
        expect(rent_term.effective_from).to eq(Date.new(2025, 1, 1))
        expect(rent_term.effective_until).to eq(Date.new(2025, 12, 31))

        expect(tenancy.charges.rent.count).to be >= 1
      end
    end

    context "when rentable unit is deactivated" do
      let(:deactivated_unit) { create(:rentable_unit, property: property, active: false, name: "Deactivated Unit") }
      let(:params) do
        {
          rentable_unit_id: deactivated_unit.id,
          agreement_type: "fixed_term",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: Date.new(2025, 12, 31),
          party_ids: [ party1.id ],
          rent_amount: "2000.00"
        }
      end

      it "returns not_found failure and prevents creation" do
        result = described_class.call(user: user, params: params)

        expect(result).to be_failure
        expect(result.failure.code).to eq(:not_found)
      end
    end

    context "when participant dates do not cover the full tenancy" do
      let(:params) do
        {
          rentable_unit_id: unit.id,
          agreement_type: "fixed_term",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: Date.new(2025, 12, 31),
          participants: [
            { party_id: party1.id, role: "tenant", effective_from: Date.new(2025, 1, 1), effective_until: Date.new(2025, 6, 30) }
          ],
          rent_amount: "2000.00"
        }
      end

      it "fails continuous tenant coverage check" do
        result = described_class.call(user: user, params: params)

        expect(result).to be_failure
        expect(result.failure.error).to include("continuous tenant coverage")
      end
    end

    context "with explicit participants array including party object" do
      let(:params) do
        {
          rentable_unit_id: unit.id,
          agreement_type: "month_to_month",
          commencement_date: Date.new(2025, 1, 1),
          participants: [
            { party: party1, role: "tenant" },
            { party_id: party2.id, role: "guarantor" }
          ],
          rent_term: {
            amount_cents: 180_000,
            due_day: 5,
            frequency: "monthly"
          }
        }
      end

      it "creates tenancy with specific roles for participants" do
        result = described_class.call(user: user, params: params)

        expect(result).to be_success
        tenancy = result.value!.data[:tenancy]
        expect(tenancy.tenancy_parties.find_by(party: party1).role).to eq("tenant")
        expect(tenancy.tenancy_parties.find_by(party: party2).role).to eq("guarantor")
      end

      it "creates tenancy with string-keyed participant and initial rent parameters" do
        string_params = {
          "rentable_unit_id" => unit.id,
          "agreement_type" => "month_to_month",
          "commencement_date" => Date.new(2025, 1, 1),
          "participants" => [
            { "party" => party1, "role" => "tenant", "effective_from" => Date.new(2025, 1, 1) }
          ],
          "initial_rent" => {
            "amount_cents" => 190_000,
            "due_day" => 1,
            "frequency" => "monthly",
            "effective_from" => Date.new(2025, 1, 1)
          }
        }
        result = described_class.call(user: user, params: string_params)
        expect(result).to be_success
        tenancy = result.value!.data[:tenancy]
        expect(tenancy.tenancy_parties.find_by(party: party1).role).to eq("tenant")
      end
    end

    context "when participant party belongs to another user" do
      let(:other_party) { create(:party, user: other_user) }

      it "returns not_found failure" do
        result = described_class.call(
          user: user,
          tenancy_params: {
            rentable_unit_id: unit.id,
            agreement_type: "month_to_month",
            commencement_date: Date.new(2025, 1, 1)
          },
          participants: [
            { party_id: other_party.id, role: "tenant" }
          ],
          initial_rent: { amount_cents: 100_000 }
        )

        expect(result).to be_failure
        expect(result.failure.code).to eq(:not_found)
      end
    end

    context "when tenancy validation fails directly" do
      it "returns validation_error failure" do
        result = described_class.call(
          user: user,
          tenancy_params: {
            rentable_unit_id: unit.id,
            agreement_type: "fixed_term",
            commencement_date: Date.new(2025, 1, 1),
            termination_date: nil
          },
          participants: [
            { party_id: party1.id, role: "tenant" }
          ],
          initial_rent: { amount_cents: 100_000 }
        )

        expect(result).to be_failure
        expect(result.failure.code).to eq(:validation_error)
        expect(result.failure.error).to include("Termination date")
      end
    end

    context "when no tenant role is present in participants" do
      let(:params) do
        {
          rentable_unit_id: unit.id,
          agreement_type: "month_to_month",
          commencement_date: Date.new(2025, 1, 1),
          participants: [
            { party_id: party1.id, role: "guarantor" }
          ],
          rent_amount: "1500.00"
        }
      end

      it "returns a failure requiring at least one tenant" do
        result = described_class.call(user: user, params: params)

        expect(result).to be_failure
        expect(result.failure.error).to include("At least one tenant participant is required")
      end
    end

    context "when no parties are provided" do
      let(:params) do
        {
          rentable_unit_id: unit.id,
          agreement_type: "fixed_term",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: Date.new(2025, 12, 31),
          rent_amount: "1500.00"
        }
      end

      it "returns a failure requiring participants" do
        result = described_class.call(user: user, params: params)

        expect(result).to be_failure
        expect(result.failure.error).to include("At least one tenant participant is required")
      end
    end

    context "when rent amount is invalid" do
      let(:params) do
        {
          rentable_unit_id: unit.id,
          agreement_type: "month_to_month",
          commencement_date: Date.new(2025, 1, 1),
          party_ids: [ party1.id ],
          rent_amount: "-50.00"
        }
      end

      it "returns a failure result and creates nothing" do
        result = nil
        expect {
          result = described_class.call(user: user, params: params)
        }.not_to change(Tenancy, :count)

        expect(result).to be_failure
        expect(result.failure.data[:rent_term]).to be_present
      end
    end

    context "concurrency race prevention on same unit" do
      let(:concurrent_params_1) do
        {
          rentable_unit_id: unit.id,
          agreement_type: "fixed_term",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: Date.new(2025, 12, 31),
          party_ids: [ party1.id ],
          rent_amount: "2000.00"
        }
      end
      let(:concurrent_params_2) do
        {
          rentable_unit_id: unit.id,
          agreement_type: "fixed_term",
          commencement_date: Date.new(2025, 6, 1),
          termination_date: Date.new(2026, 5, 31),
          party_ids: [ party2.id ],
          rent_amount: "2100.00"
        }
      end

      it "serializes concurrent creates and rejects the overlapping tenancy" do
        results = []
        threads = [
          Thread.new {
            ActiveRecord::Base.connection_pool.with_connection do
              results << described_class.call(user: user, params: concurrent_params_1)
            end
          },
          Thread.new {
            ActiveRecord::Base.connection_pool.with_connection do
              results << described_class.call(user: user, params: concurrent_params_2)
            end
          }
        ]
        threads.each(&:join)

        successes = results.select(&:success?)
        failures = results.select(&:failure?)

        expect(successes.count).to eq(1)
        expect(failures.count).to eq(1)
        expect(failures.first.failure.error).to include("already exists for this unit")
      end
    end
  end
end
