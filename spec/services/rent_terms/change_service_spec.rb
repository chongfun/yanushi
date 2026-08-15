require "rails_helper"

RSpec.describe RentTerms::ChangeService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      agreement_type: "fixed_term",
      commencement_date: Date.new(2025, 1, 1),
      termination_date: Date.new(2025, 12, 31)
    )
  end
  let!(:initial_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 200_000,
      due_day: 1,
      frequency: "monthly",
      effective_from: Date.new(2025, 1, 1),
      effective_until: Date.new(2025, 12, 31)
    )
  end

  describe ".call" do
    context "with valid change parameters on terminated tenancy" do
      let(:params) do
        {
          amount_cents: 220_000,
          due_day: 1,
          frequency: "monthly",
          effective_from: Date.new(2025, 7, 1)
        }
      end

      it "atomically closes prior term on effective_from - 1.day and creates new term capped at tenancy termination" do
        result = nil
        expect {
          result = described_class.call(user: user, tenancy: tenancy, params: params)
        }.to change(RentTerm, :count).by(1)

        expect(result).to be_success
        new_term = result.value!.data[:rent_term]
        expect(new_term.amount_cents).to eq(220_000)
        expect(new_term.effective_from).to eq(Date.new(2025, 7, 1))
        expect(new_term.effective_until).to eq(Date.new(2025, 12, 31))

        expect(initial_term.reload.effective_until).to eq(Date.new(2025, 6, 30))
      end
    end

    context "when adding a term after an intentional gap" do
      before do
        initial_term.update!(effective_until: Date.new(2025, 6, 30))
      end

      let(:params) do
        {
          amount_cents: 230_000,
          due_day: 1,
          frequency: "monthly",
          effective_from: Date.new(2025, 8, 1)
        }
      end

      it "preserves the prior term gap and does not rewrite prior effective_until to July 31" do
        result = described_class.call(user: user, tenancy: tenancy, params: params)

        expect(result).to be_success
        new_term = result.value!.data[:rent_term]
        expect(new_term.effective_from).to eq(Date.new(2025, 8, 1))
        expect(new_term.effective_until).to eq(Date.new(2025, 12, 31))
        expect(initial_term.reload.effective_until).to eq(Date.new(2025, 6, 30))
      end
    end

    context "with valid change parameters on open-ended tenancy" do
      let(:open_unit) { create(:rentable_unit, property: property, name: "Open Unit") }
      let(:open_tenancy) do
        create(:tenancy,
          rentable_unit: open_unit,
          agreement_type: "month_to_month",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: nil
        )
      end
      let!(:open_initial_term) do
        create(:rent_term,
          tenancy: open_tenancy,
          amount_cents: 180_000,
          effective_from: Date.new(2025, 1, 1),
          effective_until: nil
        )
      end

      it "creates new open-ended term with effective_until nil" do
        result = described_class.call(
          user: user,
          tenancy: open_tenancy,
          params: { amount_cents: 195_000, due_day: 1, effective_from: Date.new(2025, 6, 1) }
        )

        expect(result).to be_success
        new_term = result.value!.data[:rent_term]
        expect(new_term.effective_until).to be_nil
        expect(open_initial_term.reload.effective_until).to eq(Date.new(2025, 5, 31))
      end
    end

    context "when amount is passed in dollars string" do
      let(:params) do
        {
          amount: "2350.00",
          due_day: 5,
          frequency: "monthly",
          effective_from: Date.new(2025, 8, 1)
        }
      end

      it "converts dollar amount to amount_cents correctly" do
        result = described_class.call(user: user, tenancy: tenancy, params: params)

        expect(result).to be_success
        new_term = result.value!.data[:rent_term]
        expect(new_term.amount_cents).to eq(235_000)
        expect(new_term.due_day).to eq(5)
      end
    end

    context "when effective_from is blank" do
      it "returns a failure" do
        result = described_class.call(tenancy: tenancy, amount_cents: 200_000, effective_from: nil)
        expect(result).to be_failure
        expect(result.failure.error).to eq("Effective from date is required")
      end
    end

    context "when effective_from is before commencement_date" do
      it "returns a failure" do
        result = described_class.call(tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2024, 12, 1))
        expect(result).to be_failure
        expect(result.failure.error).to include("Effective from date cannot precede tenancy commencement date")
      end
    end

    context "when effective_from is after termination_date" do
      it "returns a failure" do
        result = described_class.call(tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2026, 1, 15))
        expect(result).to be_failure
        expect(result.failure.error).to include("Effective from date cannot exceed tenancy termination date")
      end
    end

    context "when effective_from is before current term's start date" do
      let(:prior_unit) { create(:rentable_unit, property: property, name: "Prior Unit") }
      let(:open_tenancy) do
        create(:tenancy,
          rentable_unit: prior_unit,
          agreement_type: "month_to_month",
          commencement_date: Date.new(2024, 1, 1),
          termination_date: nil
        )
      end
      let!(:prior_term) do
        create(:rent_term,
          tenancy: open_tenancy,
          amount_cents: 150_000,
          effective_from: Date.new(2025, 1, 1),
          effective_until: nil
        )
      end

      let(:params) do
        {
          amount_cents: 220_000,
          due_day: 1,
          effective_from: Date.new(2024, 12, 1)
        }
      end

      it "returns a failure and preserves existing terms" do
        result = described_class.call(user: user, tenancy: open_tenancy, params: params)

        expect(result).to be_failure
        expect(result.failure.error).to include("New rent term effective date must be after prior term start date")
        expect(prior_term.reload.effective_until).to be_nil
      end
    end

    context "when new rent term has validation errors" do
      it "returns failure with validation errors on invalid amount" do
        result = described_class.call(
          tenancy: tenancy,
          amount_cents: -500,
          effective_from: Date.new(2025, 9, 1)
        )
        expect(result).to be_failure
        expect(result.failure.code).to eq(:validation_error)
      end

      it "returns failure with validation errors on invalid frequency in params" do
        result = described_class.call(
          tenancy: tenancy,
          params: {
            amount_cents: 200_000,
            effective_from: Date.new(2025, 9, 1),
            frequency: "invalid_frequency"
          }
        )
        expect(result).to be_failure
        expect(result.failure.code).to eq(:validation_error)
        expect(result.failure.error).to include("Frequency is not included in the list")
      end
    end

    context "concurrency with simultaneous tenancy termination" do
      let(:open_unit) { create(:rentable_unit, property: property, name: "Concurrent Unit") }
      let(:concurrent_tenancy) do
        create(:tenancy,
          rentable_unit: open_unit,
          agreement_type: "month_to_month",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: nil
        )
      end
      let!(:concurrent_initial_tp) do
        create(:tenancy_party,
          tenancy: concurrent_tenancy,
          party: create(:party, user: user),
          role: "tenant",
          effective_from: Date.new(2025, 1, 1),
          effective_until: nil
        )
      end
      let!(:concurrent_initial_term) do
        create(:rent_term,
          tenancy: concurrent_tenancy,
          amount_cents: 180_000,
          effective_from: Date.new(2025, 1, 1),
          effective_until: nil
        )
      end

      it "respects freshly-committed termination date under lock" do
        # Process A terminates tenancy at 2025-06-30
        update_result = Tenancies::UpdateService.call(
          tenancy: concurrent_tenancy,
          params: { termination_date: Date.new(2025, 6, 30) }
        )
        expect(update_result).to be_success

        # Process B tries to change rent term starting at 2025-08-01 using in-memory reference
        result = described_class.call(
          tenancy: concurrent_tenancy,
          params: { amount_cents: 200_000, effective_from: Date.new(2025, 8, 1) }
        )

        expect(result).to be_failure
        expect(result.failure.error).to include("cannot exceed tenancy termination date")
      end
    end

    context "when tenancy has no prior rent terms" do
      let(:empty_unit) { create(:rentable_unit, property: property, name: "Empty Unit") }
      let(:empty_tenancy) do
        create(:tenancy,
          rentable_unit: empty_unit,
          agreement_type: "month_to_month",
          commencement_date: Date.new(2025, 1, 1),
          termination_date: nil
        )
      end

      it "creates initial rent term defaulting due_day to 1" do
        result = described_class.call(
          tenancy: empty_tenancy,
          amount_cents: 180_000,
          effective_from: Date.new(2025, 1, 1)
        )

        expect(result).to be_success
        expect(result.value!.data[:rent_term].due_day).to eq(1)
      end
    end
  end
end
