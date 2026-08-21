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
    exp_res = Expenses::CreateService.call(
      property: property,
      amount: expense_amount,
      expense_kind: "utilities",
      paid_on: due_date,
      description: "Monthly utility bill"
    )
    if exp_res.success?
      Charges::CreateReimbursementService.call(
        expense: exp_res.value!.data[:expense],
        tenancy: tenancy,
        amount: expense_amount,
        charge_date: due_date,
        description: "Utility reimbursement"
      )
    end
    Receipts::CreateService.call(tenancy: tenancy, payer_party: party, amount: expense_amount, received_on: payment_date, payment_method: "ach")
  end

  Expenses::CreateService.call(property: property, amount: rand(200...300), expense_kind: "repairs", paid_on: Date.current - 1.year, description: "A/C tune-up")
  Expenses::CreateService.call(property: property, amount: rand(150...250), expense_kind: "repairs", paid_on: Date.current - 1.month, description: "Unclog toilet")
  Expenses::CreateService.call(property: property, amount: rand(250...350), expense_kind: "repairs", paid_on: Date.current, description: "A/C tune-up")

  dep_res = SecurityDeposits::CreateService.call(
    tenancy: tenancy,
    required_amount: "2400.00",
    due_on: Date.current - 1.year
  )
  if dep_res.success?
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: dep_res.value!.data[:security_deposit],
      party: party,
      amount: "2400.00",
      occurred_on: Date.current - 1.year,
      memo: "Initial deposit receipt"
    )
  end
end
