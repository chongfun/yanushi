# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

if Rails.env.development?
  user = User.find_by(email: "me@kylechong.com")
  User.create!(email: "me@kylechong.com", password: "password123") if user.nil?
  rp = RentalProperty.create!(user: user, address: "1#{rand(1000)} Main St", property_type: "residential", square_footage: 1500)
  tenant = Tenant.create!(user: user, name: "John Doe", email_address: "john@kylechong.com", phone_number: "123-456-7890")
  lease = Lease.create!(rental_property: rp, tenants: [ tenant ], lease_type: "term", annual_rental_amount: 14400, commencement_date: Date.current - 1.year, termination_date: Date.current + 1.year, security_deposit: 1200, late_period_days: 3)
  lease.scheduled_rents.where("due_date < ?", Date.current - 1.month).each do |sr|
    payment = RentPayment.create!(scheduled_rent: sr, amount: 1200, payment_date: sr.due_date + rand(lease.late_period_days), payment_method: "ach")
    expense = Expense.create!(rental_property: rp, amount: rand(100...200), category: "utilities", expense_date: sr.due_date)
    UtilityPayment.create!(lease: lease, amount: expense.amount, payment_date: payment.payment_date, payment_method: "ach")
  end

  Expense.create!(rental_property: rp, amount: rand(200...300), category: "repairs", expense_date: Date.current - 1.year, description: "A/C tune-up")
  Expense.create!(rental_property: rp, amount: rand(150...250), category: "repairs", expense_date: Date.current - 1.month, description: "Unclug toilet")
  Expense.create!(rental_property: rp, amount: rand(250...350), category: "repairs", expense_date: Date.current, description: "A/C tune-up")
end
