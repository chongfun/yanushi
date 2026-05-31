require "rails_helper"

RSpec.describe ServiceResult do
  it "wraps successful data in a dry-monads Success" do
    result = described_class.success("saved")

    expect(result).to be_success
    expect(result.value!).to be_a(described_class)
    expect(result.value!.data).to eq("saved")
  end

  it "wraps failures in a dry-monads Failure with typed details" do
    result = described_class.failure(error: "Invalid input", code: :validation_error)

    expect(result).to be_failure
    expect(result.failure).to be_a(described_class)
    expect(result.failure.error).to eq("Invalid input")
    expect(result.failure.code).to eq(:validation_error)
  end
end
