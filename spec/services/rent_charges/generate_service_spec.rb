require "rails_helper"

RSpec.describe RentCharges::GenerateService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.new(2026, 1, 1),
      termination_date: Date.new(2026, 12, 31)
    )
  end
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 180_000,
      due_day: 1,
      frequency: "monthly",
      effective_from: Date.new(2026, 1, 1),
      effective_until: Date.new(2026, 12, 31)
    )
  end

  describe ".call" do
    it "generates and posts a rent charge for the specified month" do
      result = described_class.call(
        tenancy: tenancy,
        service_month: Date.new(2026, 3, 1)
      )

      expect(result).to be_success
      charge = result.value!.data[:charge]
      entry = result.value!.data[:journal_entry]

      expect(charge.rent?).to be true
      expect(charge.amount_cents).to eq(180_000)
      expect(charge.charge_date).to eq(Date.new(2026, 3, 1))
      expect(charge.due_on).to eq(Date.new(2026, 3, 1))
      expect(charge.service_period_start).to eq(Date.new(2026, 3, 1))
      expect(charge.service_period_end).to eq(Date.new(2026, 3, 31))
      expect(charge.description).to eq("Rent - March 2026")
      expect(charge.posted?).to be true
      expect(entry).to be_present
    end

    it "is idempotent on repeated calls for the same month" do
      result1 = described_class.call(tenancy: tenancy, service_month: Date.new(2026, 4, 1))
      expect(result1).to be_success

      expect {
        result2 = described_class.call(tenancy: tenancy, service_month: Date.new(2026, 4, 15))
        expect(result2).to be_success
        expect(result2.value!.data[:charge].id).to eq(result1.value!.data[:charge].id)
      }.not_to change(Charge, :count)
    end

    it "returns success nil if there is no active rent term covering the month" do
      result = described_class.call(tenancy: tenancy, service_month: Date.new(2027, 2, 1))
      expect(result).to be_success
      expect(result.value!.data).to be_nil
    end

    it "returns success nil if service period end precedes start" do
      tenancy.update_columns(termination_date: Date.new(2026, 5, 10))
      rent_term.update_columns(effective_from: Date.new(2026, 5, 15))

      result = described_class.call(tenancy: tenancy, service_month: Date.new(2026, 5, 1))
      expect(result).to be_success
      expect(result.value!.data).to be_nil
    end

    it "returns failure for unpersisted tenancy" do
      result = described_class.call(tenancy: Tenancy.new, service_month: Date.new(2026, 3, 1))
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
    end

    it "returns failure for invalid service month" do
      result = described_class.call(tenancy: tenancy, service_month: "invalid-date")
      expect(result).to be_failure
      expect(result.failure.code).to eq(:invalid_input)
    end

    it "handles various service_month input types including string and time" do
      res1 = described_class.call(tenancy: tenancy, service_month: "2026-06-01")
      expect(res1).to be_success

      res2 = described_class.call(tenancy: tenancy, service_month: Time.zone.parse("2026-07-01 12:00:00"))
      expect(res2).to be_success

      res3 = described_class.call(tenancy: tenancy, service_month: "")
      expect(res3).to be_failure
      expect(res3.failure.code).to eq(:invalid_input)
    end

    it "handles RecordNotUnique race conditions gracefully" do
      existing = create(:charge, :posted, :rent,
        tenancy: tenancy,
        amount_cents: 180_000,
        rent_term: rent_term,
        charge_date: Date.new(2026, 8, 1),
        due_on: Date.new(2026, 8, 1),
        service_period_start: Date.new(2026, 8, 1),
        service_period_end: Date.new(2026, 8, 31)
      )

      # When existing charge is found on rescue
      allow(Charges::CreateService).to receive(:call).and_raise(ActiveRecord::RecordNotUnique, "Duplicate")
      allow(tenancy.charges).to receive_message_chain(:where, :active, :first).and_return(nil, existing)
      result = described_class.call(tenancy: tenancy, service_month: Date.new(2026, 8, 1))
      expect(result).to be_success

      # When existing charge is not found on rescue
      allow(tenancy.charges).to receive_message_chain(:where, :active, :first).and_return(nil, nil)
      res_err = described_class.call(tenancy: tenancy, service_month: Date.new(2026, 9, 1))
      expect(res_err).to be_failure
      expect(res_err.failure.code).to eq(:conflict)
    end

    it "returns conflict failure when existing charge has different due_on or term" do
      described_class.call(tenancy: tenancy, service_month: Date.new(2026, 3, 1))
      existing = tenancy.charges.rent.first

      # Different due_on
      existing.update_columns(due_on: Date.new(2026, 3, 15))
      expect(described_class.call(tenancy: tenancy, service_month: Date.new(2026, 3, 1))).to be_failure

      # Different rent term
      rent_term.update_columns(effective_until: Date.new(2026, 6, 30))
      other_term = create(:rent_term, tenancy: tenancy, amount_cents: 180_000, effective_from: Date.new(2026, 7, 1), effective_until: Date.new(2026, 12, 31))
      existing.update_columns(due_on: Date.new(2026, 3, 1), rent_term_id: other_term.id)
      expect(described_class.call(tenancy: tenancy, service_month: Date.new(2026, 3, 1))).to be_failure
    end
  end
end
