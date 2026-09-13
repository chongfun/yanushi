# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

return unless Rails.env.development? || Rails.env.test? || ENV["FORCE_SEEDS"] == "true"

puts "== Seeding Yanushi demonstration data =="

# 1. User & Chart of Accounts
user = User.find_by(email: "me@kylechong.com")
if user.nil?
  user = User.create!(email: "me@kylechong.com", password: "password123")
else
  Accounting::ChartOfAccounts.ensure_for(user)
end

today = Date.current
this_year = today.year
prev_year = this_year - 1

puts "Creating contacts and parties..."

# 2. Contacts & Parties
party_homer = Party.find_or_create_by!(user: user, display_name: "Homer Simpson") do |p|
  p.party_type = "individual"
  p.email_address = "homer@springfield.net"
  p.phone_number = "555-0100"
end
party_homer.party_aliases.find_or_create_by!(alias_name: "HOMER J SIMPSON")
party_homer.party_aliases.find_or_create_by!(alias_name: "@Homer-Simpson")

party_marge = Party.find_or_create_by!(user: user, display_name: "Marge Simpson") do |p|
  p.party_type = "individual"
  p.email_address = "marge@springfield.net"
  p.phone_number = "555-0101"
end

party_sarah = Party.find_or_create_by!(user: user, display_name: "Sarah Connor") do |p|
  p.party_type = "individual"
  p.email_address = "sarah.connor@cyberdyne.org"
  p.phone_number = "415-555-0199"
end
party_sarah.party_aliases.find_or_create_by!(alias_name: "SARAH J CONNOR")

party_miles = Party.find_or_create_by!(user: user, display_name: "Miles Dyson") do |p|
  p.party_type = "individual"
  p.email_address = "miles.dyson@cyberdyne.org"
  p.phone_number = "415-555-0188"
end

party_john = Party.find_or_create_by!(user: user, display_name: "John Connor") do |p|
  p.party_type = "individual"
  p.email_address = "john@resistance.io"
  p.phone_number = "415-555-0177"
end

party_cyberdyne = Party.find_or_create_by!(user: user, display_name: "Cyberdyne Systems Inc") do |p|
  p.party_type = "organization"
  p.email_address = "billing@cyberdyne.org"
  p.phone_number = "415-555-9000"
end

party_arthur = Party.find_or_create_by!(user: user, display_name: "Arthur Dent") do |p|
  p.party_type = "individual"
  p.email_address = "arthur@dent.co.uk"
  p.phone_number = "617-555-4242"
end
party_arthur.party_aliases.find_or_create_by!(alias_name: "A DENT")

party_tricia = Party.find_or_create_by!(user: user, display_name: "Tricia McMillan") do |p|
  p.party_type = "individual"
  p.email_address = "trillian@galaxy.org"
  p.phone_number = "617-555-4200"
end
party_tricia.party_aliases.find_or_create_by!(alias_name: "Trillian")

# Vendors
Party.find_or_create_by!(user: user, display_name: "Apex Plumbing LLC") do |p|
  p.party_type = "organization"
  p.email_address = "service@apexplumbing.com"
  p.phone_number = "415-555-7800"
end

Party.find_or_create_by!(user: user, display_name: "City Water & Power") do |p|
  p.party_type = "organization"
  p.email_address = "billing@citywaterpower.gov"
  p.phone_number = "800-555-0199"
end

puts "Creating Property 1: 742 Evergreen Terrace (Single-Family, Overdue Scenario)..."

# ==============================================================================
# Property 1: 742 Evergreen Terrace (Single-Family Residence)
# Demonstrates: Single family, active tenancy, overdue balance outside grace period
# ==============================================================================
prop_1 = Property.find_or_create_by!(user: user, address: "742 Evergreen Terrace") do |p|
  p.asset_type = "single_family"
  p.square_footage = 2200
end

unit_1 = prop_1.rentable_units.find_or_create_by!(name: "Main Residence") do |u|
  u.square_footage = 2200
  u.active = true
end

# Active 1-year tenancy: started 8 months ago, ends in 4 months
tenancy_1 = unit_1.tenancies.find { |t| t.tenancy_parties.any? { |tp| tp.party_id == party_homer.id } } || unit_1.tenancies.first
if tenancy_1.nil?
  tenancy_1 = unit_1.tenancies.create!(
    commencement_date: today - 8.months,
    termination_date: today + 4.months,
    agreement_type: "fixed_term",
    late_period_days: 5
  )
end

tenancy_1.tenancy_parties.find_or_create_by!(party: party_homer, role: "tenant") do |tp|
  tp.effective_from = tenancy_1.commencement_date
  tp.effective_until = tenancy_1.termination_date
end

tenancy_1.tenancy_parties.find_or_create_by!(party: party_marge, role: "occupant") do |tp|
  tp.effective_from = tenancy_1.commencement_date
  tp.effective_until = tenancy_1.termination_date
end

if tenancy_1.rent_terms.empty?
  tenancy_1.rent_terms.create!(
    amount_cents: 280_000, # $2,800/mo
    due_day: 1,
    frequency: "monthly",
    effective_from: tenancy_1.commencement_date,
    effective_until: tenancy_1.termination_date
  )
end

# Security deposit: $2,800 received
if tenancy_1.security_deposit.nil?
  dep_res = SecurityDeposits::CreateService.call(
    tenancy: tenancy_1,
    required_amount: "2800.00",
    due_on: tenancy_1.commencement_date
  )
  if dep_res.success?
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: dep_res.value!.data[:security_deposit],
      party: party_homer,
      amount: "2800.00",
      occurred_on: tenancy_1.commencement_date,
      memo: "Initial security deposit receipt"
    )
  end
end

# Generate rent charges through today
RentCharges::GenerateThroughService.call(tenancy: tenancy_1, through: today)

# Homer paid months from 8 months ago through 2 months ago; last month and current month remain UNPAID
# (guaranteeing an overdue balance > 0 outside the 5-day grace period)
(2..8).each do |months_ago|
  charge_date = (today - months_ago.months).beginning_of_month
  next if charge_date < tenancy_1.commencement_date
  next if tenancy_1.termination_date && charge_date > tenancy_1.termination_date

  ref_code = "ACH-SIMP-#{charge_date.strftime('%Y%m')}"
  unless Receipt.exists?(tenancy: tenancy_1, external_reference: ref_code)
    Receipts::CreateService.call(
      tenancy: tenancy_1,
      payer_party: party_homer,
      amount_cents: 280_000,
      received_on: charge_date + 2.days,
      payment_method: "ach",
      external_reference: ref_code,
      memo: "Monthly rent via direct debit"
    )
  end
end

# Operating expenses for Property 1
unless Expense.exists?(property: prop_1, external_reference: "INS-SIMP-#{prev_year}")
  Expenses::CreateService.call(
    property: prop_1,
    expense_kind: "insurance",
    paid_on: Date.new(prev_year, 6, 15),
    amount_cents: 185_000,
    vendor_name: "Springfield Mutual Insurance",
    external_reference: "INS-SIMP-#{prev_year}",
    description: "Annual hazard and property insurance"
  )
end

unless Expense.exists?(property: prop_1, external_reference: "REP-SIMP-01")
  Expenses::CreateService.call(
    property: prop_1,
    expense_kind: "repairs",
    paid_on: Date.new(prev_year, 9, 20),
    amount_cents: 35_000,
    vendor_name: "Apex Plumbing LLC",
    external_reference: "REP-SIMP-01",
    description: "Main drain clearing and cleanout repair"
  )
end

unless Expense.exists?(property: prop_1, external_reference: "LND-SIMP-RECENT")
  Expenses::CreateService.call(
    property: prop_1,
    expense_kind: "cleaning_and_maintenance",
    paid_on: today - 1.month,
    amount_cents: 12_000,
    vendor_name: "Green Thumb Landscaping",
    external_reference: "LND-SIMP-RECENT",
    description: "Seasonal yard maintenance and pruning"
  )
end

# Tax profiles for Property 1: fully configured, ready for Schedule E
PropertyTaxProfile.find_or_create_by!(property: prop_1, tax_year: prev_year) do |tp|
  tp.schedule_e_property_type = "single_family_residence"
end
PropertyTaxProfile.find_or_create_by!(property: prop_1, tax_year: this_year) do |tp|
  tp.schedule_e_property_type = "single_family_residence"
end

puts "Creating Property 2: 1042 Elm Street (Multi-Family Triplex, Vacancy, Rent Term History, Tax Review)..."

# ==============================================================================
# Property 2: 1042 Elm Street (Multi-Family Triplex)
# Demonstrates: Triplex, month-to-month, rent increase, past tenancy, deposit deduction
# and refund, upcoming tenancy, vacant unit, tax review items (resolved + unresolved)
# ==============================================================================
prop_2 = Property.find_or_create_by!(user: user, address: "1042 Elm Street") do |p|
  p.asset_type = "multifamily"
  p.square_footage = 3600
end

unit_2a = prop_2.rentable_units.find_or_create_by!(name: "Unit 101 - Ground Floor") do |u|
  u.square_footage = 1200
  u.active = true
end

unit_2b = prop_2.rentable_units.find_or_create_by!(name: "Unit 201 - Upper West") do |u|
  u.square_footage = 1200
  u.active = true
end

# Unit 202 is an active rentable unit that is VACANT
prop_2.rentable_units.find_or_create_by!(name: "Unit 202 - Upper East") do |u|
  u.square_footage = 1200
  u.active = true
end

# ------------------------------------------------------------------------------
# Tenancy 2A (Unit 101): Month-to-Month, Rent Term Increase, Utility Reimbursement
# ------------------------------------------------------------------------------
comm_2a = Date.new(prev_year, 1, 1)
tenancy_2a = unit_2a.tenancies.find { |t| t.tenancy_parties.any? { |tp| tp.party_id == party_sarah.id } } || unit_2a.tenancies.first
if tenancy_2a.nil?
  tenancy_2a = unit_2a.tenancies.create!(
    commencement_date: comm_2a,
    termination_date: nil,
    agreement_type: "month_to_month",
    late_period_days: 5
  )
end

tenancy_2a.tenancy_parties.find_or_create_by!(party: party_sarah, role: "tenant") do |tp|
  tp.effective_from = tenancy_2a.commencement_date
  tp.effective_until = nil
end

# Rent term 1: $1,800 from prev_year until end of prev_year; Rent term 2: Increased to $1,950 from next Jan 1
if tenancy_2a.rent_terms.empty?
  term_1_start = tenancy_2a.commencement_date
  term_2_start = Date.new(term_1_start.year + 1, 1, 1)
  tenancy_2a.rent_terms.create!(
    amount_cents: 180_000,
    due_day: 1,
    frequency: "monthly",
    effective_from: term_1_start,
    effective_until: term_2_start - 1.day
  )
  tenancy_2a.rent_terms.create!(
    amount_cents: 195_000,
    due_day: 1,
    frequency: "monthly",
    effective_from: term_2_start,
    effective_until: nil
  )
end

# Security deposit: $1,800 received
if tenancy_2a.security_deposit.nil?
  dep_res = SecurityDeposits::CreateService.call(
    tenancy: tenancy_2a,
    required_amount: "1800.00",
    due_on: tenancy_2a.commencement_date
  )
  if dep_res.success?
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: dep_res.value!.data[:security_deposit],
      party: party_sarah,
      amount: "1800.00",
      occurred_on: tenancy_2a.commencement_date,
      memo: "Initial security deposit receipt"
    )
  end
end

RentCharges::GenerateThroughService.call(tenancy: tenancy_2a, through: today)

# Sarah Connor pays all rent on time via Zelle
cursor_date = tenancy_2a.commencement_date
while cursor_date <= today.beginning_of_month
  ref_code = "ZEL-SC-#{cursor_date.strftime('%Y%m')}"
  rent_amt = cursor_date.year == tenancy_2a.commencement_date.year ? 180_000 : 195_000

  unless Receipt.exists?(tenancy: tenancy_2a, external_reference: ref_code)
    Receipts::CreateService.call(
      tenancy: tenancy_2a,
      payer_party: party_sarah,
      amount_cents: rent_amt,
      received_on: cursor_date + 1.day,
      payment_method: "zelle",
      external_reference: ref_code,
      memo: "Monthly rent via Zelle"
    )
  end

  cursor_date = cursor_date.next_month
end

# Utility expense and reimbursement for Unit 101
unless Expense.exists?(property: prop_2, external_reference: "UTIL-ELM-#{prev_year}")
  exp_res = Expenses::CreateService.call(
    property: prop_2,
    expense_kind: "utilities",
    paid_on: today - 1.month,
    amount_cents: 85_00,
    vendor_name: "City Water & Power",
    external_reference: "UTIL-ELM-#{prev_year}",
    description: "Monthly water and trash billing"
  )

  if exp_res.success?
    reimb_res = Charges::CreateReimbursementService.call(
      expense: exp_res.value!.data[:expense],
      tenancy: tenancy_2a,
      amount_cents: 85_00,
      charge_date: today - 1.month + 1.day,
      description: "Water and trash reimbursement"
    )

    if reimb_res.success?
      Receipts::CreateService.call(
        tenancy: tenancy_2a,
        payer_party: party_sarah,
        amount_cents: 85_00,
        received_on: today - 1.month + 3.days,
        payment_method: "zelle",
        external_reference: "ZEL-UTIL-#{today.strftime('%Y%m')}",
        memo: "Utility reimbursement payment"
      )
    end
  end
end

# ------------------------------------------------------------------------------
# Tenancy 2B (Unit 201): Past Tenancy (Ended in prev_year, Deposit Applied & Refunded)
# ------------------------------------------------------------------------------
tenancy_2b = unit_2b.tenancies.find { |t| t.tenancy_parties.any? { |tp| tp.party_id == party_miles.id } }
if tenancy_2b.nil?
  comm_2b = Date.new(prev_year, 3, 1)
  term_2b_end = Date.new(prev_year, 12, 31)
  tenancy_2b = unit_2b.tenancies.create!(
    commencement_date: comm_2b,
    termination_date: term_2b_end,
    agreement_type: "fixed_term",
    late_period_days: 5
  )
end

tenancy_2b.tenancy_parties.find_or_create_by!(party: party_miles, role: "tenant") do |tp|
  tp.effective_from = tenancy_2b.commencement_date
  tp.effective_until = tenancy_2b.termination_date
end

if tenancy_2b.rent_terms.empty?
  tenancy_2b.rent_terms.create!(
    amount_cents: 200_000, # $2,000/mo
    due_day: 1,
    frequency: "monthly",
    effective_from: tenancy_2b.commencement_date,
    effective_until: tenancy_2b.termination_date
  )
end

if tenancy_2b.security_deposit.nil?
  dep_res = SecurityDeposits::CreateService.call(
    tenancy: tenancy_2b,
    required_amount: "2000.00",
    due_on: tenancy_2b.commencement_date
  )
  if dep_res.success?
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: dep_res.value!.data[:security_deposit],
      party: party_miles,
      amount: "2000.00",
      occurred_on: tenancy_2b.commencement_date,
      memo: "Initial security deposit receipt"
    )
  end
end

RentCharges::GenerateThroughService.call(tenancy: tenancy_2b, through: tenancy_2b.termination_date)

year_2b = tenancy_2b.commencement_date.year

# Months March through November paid in full
(3..11).each do |month_num|
  m_date = Date.new(year_2b, month_num, 1)
  ref_code = "CHK-DYSON-#{m_date.strftime('%Y%m')}"

  unless Receipt.exists?(tenancy: tenancy_2b, external_reference: ref_code)
    Receipts::CreateService.call(
      tenancy: tenancy_2b,
      payer_party: party_miles,
      amount_cents: 200_000,
      received_on: m_date + 2.days,
      payment_method: "check",
      external_reference: ref_code,
      memo: "Monthly rent check"
    )
  end
end

# In December: Miles paid partial rent of $1,600; remaining $400 was applied from deposit
dec_charge = tenancy_2b.charges.where(charge_kind: "rent").find_by("charge_date >= ?", Date.new(year_2b, 12, 1))
dec_ref = "CHK-DYSON-#{year_2b}12"
unless Receipt.exists?(tenancy: tenancy_2b, external_reference: dec_ref)
  Receipts::CreateService.call(
    tenancy: tenancy_2b,
    payer_party: party_miles,
    amount_cents: 160_000,
    received_on: Date.new(year_2b, 12, 2),
    payment_method: "check",
    external_reference: dec_ref,
    memo: "Partial December rent check"
  )
end

deposit_2b = tenancy_2b.security_deposit
if deposit_2b && dec_charge && !deposit_2b.transactions.where(transaction_kind: "applied").exists?
  # 1. Apply $400 from deposit to unpaid rent (RESOLVED item in Schedule E)
  app_1_res = SecurityDepositTransactions::ApplyService.call(
    security_deposit: deposit_2b,
    charge: dec_charge,
    amount_cents: 40_000,
    occurred_on: Date.new(year_2b, 12, 28),
    memo: "Security deposit applied to unpaid December rent"
  )

  if app_1_res.success?
    entry_1 = app_1_res.value!.data[:journal_entry]
    PropertyTaxReviewResolution.find_or_create_by!(
      property: prop_2,
      journal_entry: entry_1,
      tax_year: year_2b
    ) do |res|
      res.treatment = "include_in_rents"
    end
  end

  # 2. Add a move-out cleaning charge and apply $150 from deposit (UNRESOLVED review item in Schedule E)
  clean_charge_res = Charges::CreateFeeService.call(
    tenancy: tenancy_2b,
    charge_kind: "other",
    amount_cents: 15_000,
    charge_date: Date.new(year_2b, 12, 29),
    due_on: Date.new(year_2b, 12, 29),
    description: "Move-out carpet and deep cleaning fee"
  )

  if clean_charge_res.success?
    clean_charge = clean_charge_res.value!.data[:charge]
    SecurityDepositTransactions::ApplyService.call(
      security_deposit: deposit_2b,
      charge: clean_charge,
      amount_cents: 15_000,
      occurred_on: Date.new(year_2b, 12, 30),
      memo: "Security deposit applied to carpet cleaning"
    )
    # Intentionally no PropertyTaxReviewResolution -> triggers needs_review status
  end

  # 3. Refund remaining deposit: $2,000 - $400 - $150 = $1,450
  SecurityDepositTransactions::RefundService.call(
    security_deposit: deposit_2b,
    party: party_miles,
    amount_cents: 145_000,
    occurred_on: Date.new(year_2b, 12, 31),
    memo: "Security deposit refund after move-out deductions"
  )
end

# ------------------------------------------------------------------------------
# Tenancy 2C (Unit 201): Upcoming Tenancy (Commences in 15 days, Advance Deposit)
# ------------------------------------------------------------------------------
tenancy_2c = unit_2b.tenancies.find { |t| t.tenancy_parties.any? { |tp| tp.party_id == party_john.id } }
if tenancy_2c.nil?
  comm_2c = today + 15.days
  term_2c = comm_2c + 1.year
  tenancy_2c = unit_2b.tenancies.create!(
    commencement_date: comm_2c,
    termination_date: term_2c,
    agreement_type: "fixed_term",
    late_period_days: 5
  )
end

tenancy_2c.tenancy_parties.find_or_create_by!(party: party_john, role: "tenant") do |tp|
  tp.effective_from = tenancy_2c.commencement_date
  tp.effective_until = tenancy_2c.termination_date
end

tenancy_2c.tenancy_parties.find_or_create_by!(party: party_sarah, role: "guarantor") do |tp|
  tp.effective_from = tenancy_2c.commencement_date
  tp.effective_until = tenancy_2c.termination_date
end

if tenancy_2c.rent_terms.empty?
  tenancy_2c.rent_terms.create!(
    amount_cents: 210_000, # $2,100/mo
    due_day: 1,
    frequency: "monthly",
    effective_from: tenancy_2c.commencement_date,
    effective_until: tenancy_2c.termination_date
  )
end

if tenancy_2c.security_deposit.nil?
  dep_res = SecurityDeposits::CreateService.call(
    tenancy: tenancy_2c,
    required_amount: "2100.00",
    due_on: tenancy_2c.commencement_date
  )
  if dep_res.success?
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: dep_res.value!.data[:security_deposit],
      party: party_john,
      amount: "2100.00",
      occurred_on: [ today, tenancy_2c.commencement_date ].min,
      memo: "Advance security deposit for upcoming lease"
    )
  end
end

# Tax profiles for Property 2
PropertyTaxProfile.find_or_create_by!(property: prop_2, tax_year: prev_year) do |tp|
  tp.schedule_e_property_type = "multi_family_residence"
end
PropertyTaxProfile.find_or_create_by!(property: prop_2, tax_year: this_year) do |tp|
  tp.schedule_e_property_type = "multi_family_residence"
end

puts "Creating Property 3: 500 Market Street (Commercial, Grace Period, Missing Tax Profile)..."

# ==============================================================================
# Property 3: 500 Market Street (Commercial Retail Space)
# Demonstrates: Commercial asset type, organization tenant, grace period balance,
# missing Schedule E tax profile in filing tax year
# ==============================================================================
prop_3 = Property.find_or_create_by!(user: user, address: "500 Market Street") do |p|
  p.asset_type = "commercial"
  p.square_footage = 2800
end

unit_3 = prop_3.rentable_units.find_or_create_by!(name: "Suite 100 - Retail Front") do |u|
  u.square_footage = 2800
  u.active = true
end

tenancy_3 = unit_3.tenancies.find { |t| t.tenancy_parties.any? { |tp| tp.party_id == party_cyberdyne.id } } || unit_3.tenancies.first
if tenancy_3.nil?
  comm_3 = today - 18.months
  term_3 = today + 18.months
  tenancy_3 = unit_3.tenancies.create!(
    commencement_date: comm_3,
    termination_date: term_3,
    agreement_type: "fixed_term",
    late_period_days: 35 # 35-day grace period keeps current month from being overdue
  )
end

tenancy_3.tenancy_parties.find_or_create_by!(party: party_cyberdyne, role: "tenant") do |tp|
  tp.effective_from = tenancy_3.commencement_date
  tp.effective_until = tenancy_3.termination_date
end

if tenancy_3.rent_terms.empty?
  tenancy_3.rent_terms.create!(
    amount_cents: 450_000, # $4,500/mo
    due_day: 1,
    frequency: "monthly",
    effective_from: tenancy_3.commencement_date,
    effective_until: tenancy_3.termination_date
  )
end

if tenancy_3.security_deposit.nil?
  dep_res = SecurityDeposits::CreateService.call(
    tenancy: tenancy_3,
    required_amount: "9000.00",
    due_on: tenancy_3.commencement_date
  )
  if dep_res.success?
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: dep_res.value!.data[:security_deposit],
      party: party_cyberdyne,
      amount: "9000.00",
      occurred_on: tenancy_3.commencement_date,
      memo: "Commercial security deposit"
    )
  end
end

RentCharges::GenerateThroughService.call(tenancy: tenancy_3, through: today)

# All past months paid up to last month; current month remains unpaid (inside 35-day grace period)
cursor_date = tenancy_3.commencement_date.beginning_of_month
while cursor_date < today.beginning_of_month
  break if tenancy_3.termination_date && cursor_date > tenancy_3.termination_date
  ref_code = "ACH-CYBER-#{cursor_date.strftime('%Y%m')}"

  unless Receipt.exists?(tenancy: tenancy_3, external_reference: ref_code)
    Receipts::CreateService.call(
      tenancy: tenancy_3,
      payer_party: party_cyberdyne,
      amount_cents: 450_000,
      received_on: cursor_date + 5.days,
      payment_method: "ach",
      external_reference: ref_code,
      memo: "Monthly commercial rent wire"
    )
  end

  cursor_date = cursor_date.next_month
end

# Commercial operating expenses
unless Expense.exists?(property: prop_3, external_reference: "TAX-COMM-#{prev_year}")
  Expenses::CreateService.call(
    property: prop_3,
    expense_kind: "taxes",
    paid_on: Date.new(prev_year, 4, 10),
    amount_cents: 620_000,
    vendor_name: "County Tax Collector",
    external_reference: "TAX-COMM-#{prev_year}",
    description: "Annual commercial property tax assessment"
  )
end

unless Expense.exists?(property: prop_3, external_reference: "HVAC-COMM-#{prev_year}")
  Expenses::CreateService.call(
    property: prop_3,
    expense_kind: "repairs",
    paid_on: Date.new(prev_year, 7, 15),
    amount_cents: 85_000,
    vendor_name: "Bay Area Mechanical",
    external_reference: "HVAC-COMM-#{prev_year}",
    description: "Quarterly rooftop HVAC inspection and filter service"
  )
end

unless Expense.exists?(property: prop_3, external_reference: "LEGAL-COMM-#{prev_year}")
  Expenses::CreateService.call(
    property: prop_3,
    expense_kind: "legal_and_professional",
    paid_on: Date.new(prev_year, 2, 1),
    amount_cents: 120_000,
    vendor_name: "Morrison & Foerster LLP",
    external_reference: "LEGAL-COMM-#{prev_year}",
    description: "Commercial lease review and legal advisory"
  )
end

# NOTE: We intentionally DO NOT create a PropertyTaxProfile for prev_year on Property 3!
# This triggers the "needs_profile" state in Schedule E for prev_year.
PropertyTaxProfile.find_or_create_by!(property: prop_3, tax_year: this_year) do |tp|
  tp.schedule_e_property_type = "commercial"
end

puts "Creating Property 4: 84 Beacon Street (Historic Brownstone Duplex, Waived Fee, Venmo)..."

# ==============================================================================
# Property 4: 84 Beacon Street (Historic Multi-Family Duplex)
# Demonstrates: Duplex, fee waiver/reversal in ledger, P2P Venmo payments, Ready tax status
# ==============================================================================
prop_4 = Property.find_or_create_by!(user: user, address: "84 Beacon Street") do |p|
  p.asset_type = "multifamily"
  p.square_footage = 2400
end

unit_4a = prop_4.rentable_units.find_or_create_by!(name: "Unit 1 - Garden Level") do |u|
  u.square_footage = 1200
  u.active = true
end

unit_4b = prop_4.rentable_units.find_or_create_by!(name: "Unit 2 - Penthouse") do |u|
  u.square_footage = 1200
  u.active = true
end

# ------------------------------------------------------------------------------
# Tenancy 4A (Unit 1): Arthur Dent (Waived Fee Demonstration)
# ------------------------------------------------------------------------------
tenancy_4a = unit_4a.tenancies.find { |t| t.tenancy_parties.any? { |tp| tp.party_id == party_arthur.id } } || unit_4a.tenancies.first
if tenancy_4a.nil?
  comm_4a = today - 1.year
  term_4a = today + 1.year
  tenancy_4a = unit_4a.tenancies.create!(
    commencement_date: comm_4a,
    termination_date: term_4a,
    agreement_type: "fixed_term",
    late_period_days: 5
  )
end

tenancy_4a.tenancy_parties.find_or_create_by!(party: party_arthur, role: "tenant") do |tp|
  tp.effective_from = tenancy_4a.commencement_date
  tp.effective_until = tenancy_4a.termination_date
end

if tenancy_4a.rent_terms.empty?
  tenancy_4a.rent_terms.create!(
    amount_cents: 220_000, # $2,200/mo
    due_day: 1,
    frequency: "monthly",
    effective_from: tenancy_4a.commencement_date,
    effective_until: tenancy_4a.termination_date
  )
end

if tenancy_4a.security_deposit.nil?
  dep_res = SecurityDeposits::CreateService.call(
    tenancy: tenancy_4a,
    required_amount: "2200.00",
    due_on: tenancy_4a.commencement_date
  )
  if dep_res.success?
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: dep_res.value!.data[:security_deposit],
      party: party_arthur,
      amount: "2200.00",
      occurred_on: tenancy_4a.commencement_date,
      memo: "Initial security deposit receipt"
    )
  end
end

RentCharges::GenerateThroughService.call(tenancy: tenancy_4a, through: today)

# Arthur Dent pays each month via Zelle
cursor_date = tenancy_4a.commencement_date.beginning_of_month
while cursor_date <= today.beginning_of_month
  break if tenancy_4a.termination_date && cursor_date > tenancy_4a.termination_date
  ref_code = "ZEL-DENT-#{cursor_date.strftime('%Y%m')}"

  unless Receipt.exists?(tenancy: tenancy_4a, external_reference: ref_code)
    Receipts::CreateService.call(
      tenancy: tenancy_4a,
      payer_party: party_arthur,
      amount_cents: 220_000,
      received_on: cursor_date + 1.day,
      payment_method: "zelle",
      external_reference: ref_code,
      memo: "Monthly rent via Zelle"
    )
  end

  cursor_date = cursor_date.next_month
end

# Waived Late Fee Demonstration: Late fee posted 3 months ago and waived
waived_desc = "Late fee for holiday weekend delay"
unless Charge.exists?(tenancy: tenancy_4a, description: waived_desc)
  fee_res = Charges::CreateFeeService.call(
    tenancy: tenancy_4a,
    charge_kind: "late_fee",
    amount_cents: 75_00,
    charge_date: today - 3.months,
    due_on: today - 3.months,
    description: waived_desc
  )

  if fee_res.success?
    charge_to_void = fee_res.value!.data[:charge]
    Charges::VoidService.call(
      charge: charge_to_void,
      occurred_on: today - 3.months + 2.days,
      reason: "One-time courtesy waiver for bank holiday transfer delay"
    )
  end
end

# ------------------------------------------------------------------------------
# Tenancy 4B (Unit 2): Tricia McMillan (P2P Venmo Payments)
# ------------------------------------------------------------------------------
tenancy_4b = unit_4b.tenancies.find { |t| t.tenancy_parties.any? { |tp| tp.party_id == party_tricia.id } } || unit_4b.tenancies.first
if tenancy_4b.nil?
  comm_4b = today - 1.year
  term_4b = today + 1.year
  tenancy_4b = unit_4b.tenancies.create!(
    commencement_date: comm_4b,
    termination_date: term_4b,
    agreement_type: "fixed_term",
    late_period_days: 5
  )
end

tenancy_4b.tenancy_parties.find_or_create_by!(party: party_tricia, role: "tenant") do |tp|
  tp.effective_from = tenancy_4b.commencement_date
  tp.effective_until = tenancy_4b.termination_date
end

if tenancy_4b.rent_terms.empty?
  tenancy_4b.rent_terms.create!(
    amount_cents: 240_000, # $2,400/mo
    due_day: 1,
    frequency: "monthly",
    effective_from: tenancy_4b.commencement_date,
    effective_until: tenancy_4b.termination_date
  )
end

if tenancy_4b.security_deposit.nil?
  dep_res = SecurityDeposits::CreateService.call(
    tenancy: tenancy_4b,
    required_amount: "2400.00",
    due_on: tenancy_4b.commencement_date
  )
  if dep_res.success?
    SecurityDepositTransactions::ReceiveService.call(
      security_deposit: dep_res.value!.data[:security_deposit],
      party: party_tricia,
      amount: "2400.00",
      occurred_on: tenancy_4b.commencement_date,
      memo: "Initial security deposit receipt"
    )
  end
end

RentCharges::GenerateThroughService.call(tenancy: tenancy_4b, through: today)

# Tricia pays each month via Venmo
cursor_date = tenancy_4b.commencement_date.beginning_of_month
while cursor_date <= today.beginning_of_month
  break if tenancy_4b.termination_date && cursor_date > tenancy_4b.termination_date
  ref_code = "VEN-TRIL-#{cursor_date.strftime('%Y%m')}"

  unless Receipt.exists?(tenancy: tenancy_4b, external_reference: ref_code)
    Receipts::CreateService.call(
      tenancy: tenancy_4b,
      payer_party: party_tricia,
      amount_cents: 240_000,
      received_on: cursor_date + 1.day,
      payment_method: "venmo",
      external_reference: ref_code,
      memo: "Monthly rent via Venmo"
    )
  end

  cursor_date = cursor_date.next_month
end

# Expenses for Property 4
unless Expense.exists?(property: prop_4, external_reference: "ROOF-BEAC-01")
  Expenses::CreateService.call(
    property: prop_4,
    expense_kind: "repairs",
    paid_on: today - 4.months,
    amount_cents: 40_000,
    vendor_name: "Beacon Hill Slate & Copper",
    external_reference: "ROOF-BEAC-01",
    description: "Slate roof inspection and tile repair"
  )
end

unless Expense.exists?(property: prop_4, external_reference: "PEST-BEAC-01")
  Expenses::CreateService.call(
    property: prop_4,
    expense_kind: "cleaning_and_maintenance",
    paid_on: today - 2.months,
    amount_cents: 18_000,
    vendor_name: "New England Pest Solutions",
    external_reference: "PEST-BEAC-01",
    description: "Quarterly preventative pest control"
  )
end

unless Expense.exists?(property: prop_4, external_reference: "MGMT-BEAC-#{prev_year}")
  Expenses::CreateService.call(
    property: prop_4,
    expense_kind: "management",
    paid_on: Date.new(prev_year, 10, 1),
    amount_cents: 19_500,
    vendor_name: "Commonwealth Property Mgmt",
    external_reference: "MGMT-BEAC-#{prev_year}",
    description: "Monthly property management fee"
  )
end

unless Expense.exists?(property: prop_4, external_reference: "ADV-BEAC-#{prev_year}")
  Expenses::CreateService.call(
    property: prop_4,
    expense_kind: "advertising",
    paid_on: Date.new(prev_year, 1, 15),
    amount_cents: 15_000,
    vendor_name: "Zillow Group",
    external_reference: "ADV-BEAC-#{prev_year}",
    description: "Rental listing syndication and marketing"
  )
end

# Tax profiles for Property 4: ready for Schedule E
PropertyTaxProfile.find_or_create_by!(property: prop_4, tax_year: prev_year) do |tp|
  tp.schedule_e_property_type = "multi_family_residence"
end
PropertyTaxProfile.find_or_create_by!(property: prop_4, tax_year: this_year) do |tp|
  tp.schedule_e_property_type = "multi_family_residence"
end

puts "Creating Inbox source documents and imported transactions..."

# ==============================================================================
# Inbox & Statement Ingestion
# Demonstrates: Needs Review (matched, unmatched, ambiguous, failed),
# Processing (processing, failed statement), History (confirmed transactions)
# ==============================================================================

# 1. Successful statement with confirmed historical transactions (History tab)
doc_history = SourceDocument.find_or_create_by!(user: user, attachment_filename: "chase_checking_historical.csv") do |d|
  d.document_type = "chase_statement"
  d.status = "success"
  d.attachment_content_type = "text/csv"
  d.attachment_file = "Date,Description,Amount\n2025-10-01,Rent Trillian,2400.00\n2025-10-02,Rent Dent,2200.00"
end

# Link confirmed transactions to real receipts created earlier
hist_receipt_tricia = Receipt.where(tenancy: tenancy_4b, payment_method: "venmo").order(:received_on).first
if hist_receipt_tricia && !ImportedTransaction.exists?(confirmed_source: hist_receipt_tricia)
  ImportedTransaction.create!(
    user: user,
    source_document: doc_history,
    source: "chase",
    transaction_kind: "tenant_receipt",
    status: "confirmed",
    confirmed_source: hist_receipt_tricia,
    amount_cents: hist_receipt_tricia.amount_cents,
    occurred_on: hist_receipt_tricia.received_on,
    payer_name: "Tricia McMillan",
    payment_method: "venmo",
    external_reference: hist_receipt_tricia.external_reference,
    matched_party: party_tricia,
    matched_tenancy: tenancy_4b,
    raw_text: "Unit 2 rent payment"
  )
end

hist_receipt_arthur = Receipt.where(tenancy: tenancy_4a, payment_method: "zelle").order(:received_on).first
if hist_receipt_arthur && !ImportedTransaction.exists?(confirmed_source: hist_receipt_arthur)
  ImportedTransaction.create!(
    user: user,
    source_document: doc_history,
    source: "chase",
    transaction_kind: "tenant_receipt",
    status: "confirmed",
    confirmed_source: hist_receipt_arthur,
    amount_cents: hist_receipt_arthur.amount_cents,
    occurred_on: hist_receipt_arthur.received_on,
    payer_name: "Arthur Dent",
    payment_method: "zelle",
    external_reference: hist_receipt_arthur.external_reference,
    matched_party: party_arthur,
    matched_tenancy: tenancy_4a,
    raw_text: "Unit 1 rent payment"
  )
end

# 2. Source document with pending reviewable transactions (Needs Review tab)
doc_review = SourceDocument.find_or_create_by!(user: user, attachment_filename: "zelle_transactions_current.csv") do |d|
  d.document_type = "zelle"
  d.status = "success"
  d.attachment_content_type = "text/csv"
  d.attachment_file = "Date,Sender,Amount\n#{today - 2.days},Arthur Dent,2200.00\n#{today - 3.days},Check 4021,1500.00"
end

# 2a. Matched: Ready to confirm with 1 click
unless ImportedTransaction.exists?(user: user, external_reference: "ZEL-IMP-MATCHED-01")
  ImportedTransaction.create!(
    user: user,
    source_document: doc_review,
    source: "zelle",
    transaction_kind: "tenant_receipt",
    status: "matched",
    amount_cents: 220_000,
    occurred_on: today - 2.days,
    payer_name: "Arthur Dent",
    payer_username: "A DENT",
    payment_method: "zelle",
    external_reference: "ZEL-IMP-MATCHED-01",
    matched_party: party_arthur,
    matched_tenancy: tenancy_4a,
    raw_text: "Rent payment for Unit 1"
  )
end

# 2b. Unmatched: No party or tenancy assigned
unless ImportedTransaction.exists?(user: user, external_reference: "CHK-IMP-UNMATCHED-01")
  ImportedTransaction.create!(
    user: user,
    source_document: doc_review,
    source: "chase",
    transaction_kind: "unknown",
    status: "unmatched",
    amount_cents: 150_000,
    occurred_on: today - 3.days,
    payer_name: "Oakland Property Services",
    payment_method: "check",
    external_reference: "CHK-IMP-UNMATCHED-01",
    raw_text: "Escrow refund check"
  )
end

# 2c. Ambiguous: Multiple potential candidate matches
unless ImportedTransaction.exists?(user: user, external_reference: "VEN-IMP-AMBIGUOUS-01")
  ImportedTransaction.create!(
    user: user,
    source_document: doc_review,
    source: "venmo",
    transaction_kind: "tenant_receipt",
    status: "ambiguous",
    amount_cents: 50_000,
    occurred_on: today - 1.day,
    payer_name: "Connor",
    payer_username: "@connor-fam",
    payment_method: "venmo",
    external_reference: "VEN-IMP-AMBIGUOUS-01",
    raw_text: "Partial rent payment"
  )
end

# 2d. Failed: Parse / ingestion issue
unless ImportedTransaction.exists?(user: user, external_reference: "ERR-IMP-FAILED-01")
  ImportedTransaction.create!(
    user: user,
    source_document: doc_review,
    source: "zelle",
    transaction_kind: "unknown",
    status: "failed",
    amount_cents: 10_000,
    occurred_on: today - 4.days,
    payer_name: "Unknown Transfer",
    payment_method: "zelle",
    external_reference: "ERR-IMP-FAILED-01",
    error_message: "Missing account routing identifier or reversal detected"
  )
end

# 3. In-progress statement upload (Processing tab)
SourceDocument.find_or_create_by!(user: user, attachment_filename: "venmo_batch_processing.csv") do |d|
  d.document_type = "venmo"
  d.status = "processing"
  d.attachment_content_type = "text/csv"
  d.attachment_file = "Date,Note,Amount\n#{today},Rent,1950.00"
end

# 4. Failed statement upload (Processing tab & Attention Queue)
SourceDocument.find_or_create_by!(user: user, attachment_filename: "statement_scan_corrupted.pdf") do |d|
  d.document_type = "unknown"
  d.status = "failed"
  d.attachment_content_type = "application/pdf"
  d.attachment_file = "%PDF-1.4-corrupt-data-stream-unreadable"
  d.error_message = "Unrecognized statement header format: missing recognizable transaction columns"
end

user.increment_inbox_revision!

puts "== Seed data complete! =="
puts "Portfolio Summary:"
puts "  Properties: #{user.properties.count}"
puts "  Rentable Units: #{user.rentable_units.count} (#{user.rentable_units.count { |u| u.occupied?(today) }} occupied, #{user.rentable_units.count { |u| !u.occupied?(today) }} vacant)"
puts "  Tenancies: #{user.tenancies.count}"
puts "  Source Documents: #{user.source_documents.count}"
puts "  Imported Transactions: #{user.imported_transactions.count} (#{user.imported_transactions.reviewable.count} reviewable, #{user.imported_transactions.confirmed.count} confirmed)"
