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
    expect(expense_lines.map(&:category)).to include(:advertising, :auto_and_travel, :utilities, :repairs, :other)
    expect(form_def.reference_notice).to be_nil
  end

  it "defines 2011 IRS Schedule E Part I lines with Line 3a notice" do
    def_2011 = described_class.for(2011)
    expect(def_2011.income_lines.first.label).to include("Line 3a")
    expect(def_2011.expense_lines.map(&:line_number)).to eq([ 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 19 ])
    expect(def_2011.line_for(:auto_and_travel).line_number).to eq(6)
    expect(def_2011.line_for(:utilities).line_number).to eq(17)
    expect(def_2011.line_for(:other).line_number).to eq(19)
    expect(def_2011.reference_notice).to include("2011 IRS Schedule E form revision (Line 3a rents layout)")
  end

  it "defines standard expense lines for 2012-2025 without historical notices" do
    (2012..2025).each do |year|
      definition = described_class.for(year)
      expect(definition.expense_lines.map(&:line_number)).to eq([ 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 19 ])
      expect(definition.reference_notice).to be_nil
    end
  end

  it "provides reference notice for future unsupported form years" do
    future_def = described_class.for(2028)
    expect(future_def.expense_lines.map(&:line_number)).to eq([ 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 19 ])
    expect(future_def.reference_notice).to include("reflects the 2025 IRS Schedule E reference form until the official 2028 form is published")
  end

  it "provides reference notice for pre-2011 years" do
    ancient_def = described_class.for(2009)
    expect(ancient_def.reference_notice).to include("reflects the 2011 IRS Schedule E reference form")
  end

  it "finds line definition by category" do
    util_line = form_def.line_for(:utilities)
    expect(util_line.line_number).to eq(17)
    expect(util_line.label).to eq("Utilities")
  end
end
