# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

if Rails.env.development?
  user = User.find_by(email: "me@kylechong.com")
  if user.nil?
    user = User.create!(email: "me@kylechong.com", password: "password123")
  else
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  property = Property.create!(user: user, address: "1#{rand(1000)} Main St", asset_type: "single_family", square_footage: 1500)
  unit = property.rentable_units.create!(name: "Main Unit", square_footage: 1500, active: true)
  party = Party.create!(user: user, display_name: "John Doe", party_type: "individual", email_address: "john@kylechong.com", phone_number: "123-456-7890")

  tenancy = Tenancy.create!(
    rentable_unit: unit,
    agreement_type: "fixed_term",
    commencement_date: Date.current - 1.year,
    termination_date: Date.current + 1.year,
    late_period_days: 3
  )
  tenancy.tenancy_parties.create!(party: party, role: "tenant", effective_from: Date.current - 1.year)
  tenancy.rent_terms.create!(
    amount_cents: 120_000,
    due_day: 1,
    frequency: "monthly",
    effective_from: Date.current - 1.year
  )

  RentCharges::GenerateThroughService.call(tenancy: tenancy, through: Date.current)

  (1..11).each do |months_ago|
    due_date = (Date.current - months_ago.months).beginning_of_month
    payment_date = due_date + rand(tenancy.late_period_days || 3)
    Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount: 1200.0, received_on: payment_date, payment_method: "ach")

    expense_amount = rand(100...200)
    expense = Expense.new(
      property: property,
      amount: expense_amount,
      category: "utilities",
      expense_date: due_date,
      tenant_reimbursable: true,
      reimburse_tenancy_id: tenancy.id,
      reimburse_amount: expense_amount
    )
    Expenses::SaveService.call(expense: expense)
    Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount: expense_amount, received_on: payment_date, payment_method: "ach")
  end

  Expense.create!(property: property, amount: rand(200...300), category: "repairs", expense_date: Date.current - 1.year, description: "A/C tune-up")
  Expense.create!(property: property, amount: rand(150...250), category: "repairs", expense_date: Date.current - 1.month, description: "Unclug toilet")
  Expense.create!(property: property, amount: rand(250...350), category: "repairs", expense_date: Date.current, description: "A/C tune-up")
end
