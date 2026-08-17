require "rails_helper"

RSpec.describe SecurityDeposits::CreateService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  it "creates a security deposit requirement for a tenancy" do
    result = described_class.call(
      tenancy: tenancy,
      required_amount: "2000.00",
      due_on: Date.current
    )

    expect(result).to be_success
    deposit = result.value!.data[:security_deposit]
    expect(deposit.required_amount_cents).to eq(200_000)
    expect(deposit.due_on).to eq(Date.current)
    expect(tenancy.reload.security_deposit).to eq(deposit)
  end

  it "accepts numeric amount, integer amount_cents, and string due_on" do
    t2 = create(:tenancy, rentable_unit: unit)
    res = described_class.call(
      tenancy: t2,
      required_amount: 1500,
      due_on: "2026-08-16"
    )
    expect(res).to be_success
    expect(res.value!.data[:security_deposit].required_amount_cents).to eq(150_000)

    u3 = create(:rentable_unit, property: property)
    t3 = create(:tenancy, rentable_unit: u3)
    res3 = described_class.call(
      tenancy: t3,
      required_amount_cents: 250_000,
      due_on: Date.current
    )
    expect(res3).to be_success
    expect(res3.value!.data[:security_deposit].required_amount_cents).to eq(250_000)
  end

  it "rejects string required_amount_cents" do
    t2 = create(:tenancy, rentable_unit: unit)
    res = described_class.call(
      tenancy: t2,
      required_amount_cents: "250000",
      due_on: Date.current
    )
    expect(res).to be_failure
    expect(res.failure.code).to eq(:invalid_input)
  end

  it "is idempotent when called with identical parameters" do
    res1 = described_class.call(
      tenancy: tenancy,
      required_amount_cents: 200_000,
      due_on: Date.current
    )
    expect(res1).to be_success

    res2 = described_class.call(
      tenancy: tenancy,
      required_amount_cents: 200_000,
      due_on: Date.current
    )
    expect(res2).to be_success
    expect(res2.value!.data[:security_deposit].id).to eq(res1.value!.data[:security_deposit].id)
  end

  it "returns conflict when called with differing parameters on existing deposit" do
    described_class.call(
      tenancy: tenancy,
      required_amount_cents: 200_000,
      due_on: Date.current
    )

    res = described_class.call(
      tenancy: tenancy,
      required_amount_cents: 250_000,
      due_on: Date.current
    )
    expect(res).to be_failure
    expect(res.failure.code).to eq(:conflict)
  end

  it "rejects invalid amounts or missing/invalid due_on" do
    expect(described_class.call(tenancy: Tenancy.new, required_amount: "100", due_on: Date.current).failure.code).to eq(:invalid_tenancy)
    expect(described_class.call(tenancy: tenancy, required_amount: "0", due_on: Date.current).failure.code).to eq(:invalid_input)
    expect(described_class.call(tenancy: tenancy, required_amount: "-100", due_on: Date.current).failure.code).to eq(:invalid_input)
    expect(described_class.call(tenancy: tenancy, required_amount: "100.999", due_on: Date.current).failure.code).to eq(:invalid_input)
    expect(described_class.call(tenancy: tenancy, required_amount_cents: "bad", due_on: Date.current).failure.code).to eq(:invalid_input)
    expect(described_class.call(tenancy: tenancy, required_amount: "1000", due_on: nil).failure.code).to eq(:invalid_input)
    expect(described_class.call(tenancy: tenancy, required_amount: "1000", due_on: "invalid-date").failure.code).to eq(:invalid_input)
  end

  it "handles validation failure on save" do
    allow_any_instance_of(SecurityDeposit).to receive(:save).and_return(false)
    res = described_class.call(tenancy: tenancy, required_amount_cents: 200_000, due_on: Date.current)
    expect(res).to be_failure
    expect(res.failure.code).to eq(:validation_error)
  end
end
