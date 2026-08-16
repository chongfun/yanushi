require "rails_helper"

RSpec.describe GenerateDueRentChargesJob, type: :job do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let!(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.new(2026, 1, 1),
      termination_date: Date.new(2026, 12, 31)
    )
  end
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 150_000,
      due_day: 1,
      frequency: "monthly",
      effective_from: Date.new(2026, 1, 1),
      effective_until: Date.new(2026, 12, 31)
    )
  end

  describe "#perform" do
    it "calls RentCharges::GenerateThroughService for active tenancies" do
      expect {
        described_class.new.perform(Date.new(2026, 2, 15))
      }.to change(Charge, :count).by(2) # Jan and Feb charges
    end

    it "raises GenerationError when generation fails for any tenancy" do
      allow(RentCharges::GenerateThroughService).to receive(:call).and_return(
        ServiceResult.failure(error: "Account not found", code: :missing_account)
      )

      expect {
        described_class.new.perform(Date.new(2026, 2, 15))
      }.to raise_error(GenerateDueRentChargesJob::GenerationError, /Account not found/)
    end
  end
end
