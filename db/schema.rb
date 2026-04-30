# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_29_020916) do
  create_table "expenses", force: :cascade do |t|
    t.decimal "amount"
    t.string "category"
    t.datetime "created_at", null: false
    t.string "description"
    t.date "expense_date"
    t.integer "rental_property_id", null: false
    t.datetime "updated_at", null: false
    t.index ["rental_property_id"], name: "index_expenses_on_rental_property_id"
  end

  create_table "lease_tenants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lease_id", null: false
    t.integer "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["lease_id"], name: "index_lease_tenants_on_lease_id"
    t.index ["tenant_id"], name: "index_lease_tenants_on_tenant_id"
  end

  create_table "leases", force: :cascade do |t|
    t.decimal "annual_rental_amount"
    t.date "commencement_date"
    t.datetime "created_at", null: false
    t.integer "late_period_days"
    t.integer "lease_type"
    t.integer "rental_property_id", null: false
    t.decimal "security_deposit"
    t.date "termination_date"
    t.datetime "updated_at", null: false
    t.index ["rental_property_id"], name: "index_leases_on_rental_property_id"
  end

  create_table "rent_payments", force: :cascade do |t|
    t.decimal "amount"
    t.datetime "created_at", null: false
    t.date "payment_date"
    t.string "payment_method"
    t.integer "scheduled_rent_id", null: false
    t.datetime "updated_at", null: false
    t.index ["scheduled_rent_id"], name: "index_rent_payments_on_scheduled_rent_id"
  end

  create_table "rental_properties", force: :cascade do |t|
    t.string "address"
    t.datetime "created_at", null: false
    t.integer "property_type"
    t.integer "square_footage"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_rental_properties_on_user_id"
  end

  create_table "scheduled_rents", force: :cascade do |t|
    t.decimal "amount"
    t.datetime "created_at", null: false
    t.date "due_date"
    t.integer "lease_id", null: false
    t.datetime "updated_at", null: false
    t.index ["lease_id"], name: "index_scheduled_rents_on_lease_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "tenants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address"
    t.string "mailing_address"
    t.string "name"
    t.string "phone_number"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_tenants_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  create_table "utility_payments", force: :cascade do |t|
    t.decimal "amount"
    t.datetime "created_at", null: false
    t.date "payment_date"
    t.integer "rental_property_id", null: false
    t.integer "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["rental_property_id"], name: "index_utility_payments_on_rental_property_id"
    t.index ["tenant_id"], name: "index_utility_payments_on_tenant_id"
  end

  add_foreign_key "expenses", "rental_properties"
  add_foreign_key "lease_tenants", "leases"
  add_foreign_key "lease_tenants", "tenants"
  add_foreign_key "leases", "rental_properties"
  add_foreign_key "rent_payments", "scheduled_rents"
  add_foreign_key "rental_properties", "users"
  add_foreign_key "scheduled_rents", "leases"
  add_foreign_key "sessions", "users"
  add_foreign_key "tenants", "users"
  add_foreign_key "utility_payments", "rental_properties"
  add_foreign_key "utility_payments", "tenants"
end
