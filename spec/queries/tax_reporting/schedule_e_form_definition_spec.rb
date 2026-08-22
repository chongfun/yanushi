require "rails_helper"

RSpec.describe TaxReporting::ScheduleEFormDefinition do
  let(:form_def) { described_class.for(2025) }

  it "defines the standard 2025 IRS Schedule E Part I lines" do
    income_lines = form_def.income_lines
    expect(income_lines.size).to eq(1)
    expect(income_lines.first.line_number).to eq(3)
    expect(income_lines.first.category).to eq(:rents_received)

    expense_lines = form_def.expense_lines
    expect(expense_lines.map(&:line_number)).to eq([ 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 19 ])
    expect(expense_lines.map(&:category)).to include(:advertising, :utilities, :repairs, :other)
  end

  it "finds line definition by category" do
    util_line = form_def.line_for(:utilities)
    expect(util_line.line_number).to eq(17)
    expect(util_line.label).to eq("Utilities")
  end
end
