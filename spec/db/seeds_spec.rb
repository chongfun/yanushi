# frozen_string_literal: true

require "rails_helper"

RSpec.describe "db/seeds.rb" do
  include ActiveSupport::Testing::TimeHelpers

  anchor_date = Date.new(2026, 9, 15)

  after(:all) do
    ActiveRecord::Tasks::DatabaseTasks.truncate_all
  end

  def verify_demonstration_states!(anchor_date)
    user = User.find_by!(email: "me@kylechong.com")

    # 1. Structural counts
    expect(Property.count).to eq(4)
    expect(RentableUnit.count).to eq(7)
    expect(Tenancy.count).to eq(7)
    expect(PropertyTaxProfile.count).to eq(7)

    # 2. Tenancy states at anchor date
    unit_1 = RentableUnit.joins(:property).find_by!(properties: { address: "742 Evergreen Terrace" })
    tenancy_1 = unit_1.tenancies.first
    expect(tenancy_1.active?(anchor_date)).to be true

    unit_2b = RentableUnit.joins(:property).find_by!(properties: { address: "1042 Elm Street" }, name: "Unit 201 - Upper West")
    tenancy_miles = unit_2b.tenancies.find { |t| t.tenancy_parties.any? { |tp| tp.party.display_name == "Miles Dyson" } }
    tenancy_john = unit_2b.tenancies.find { |t| t.tenancy_parties.any? { |tp| tp.party.display_name == "John Connor" } }

    expect(tenancy_miles.past?(anchor_date)).to be true
    expect(tenancy_john.upcoming?(anchor_date)).to be true

    # 3. Schedule E states for filing year 2025
    statuses = Reports::ScheduleEStatusesQuery.call(user: user, tax_year: 2025)
    prop_1_status = statuses.find { |s| s.property.address == "742 Evergreen Terrace" }
    prop_2_status = statuses.find { |s| s.property.address == "1042 Elm Street" }
    prop_3_status = statuses.find { |s| s.property.address == "500 Market Street" }
    prop_4_status = statuses.find { |s| s.property.address == "84 Beacon Street" }

    expect(prop_1_status.state).to eq(:ready)
    expect(prop_4_status.state).to eq(:ready)
    expect(prop_2_status.state).to eq(:needs_review)
    expect(prop_3_status.state).to eq(:needs_profile)

    # 4. Attention items at anchor date
    travel_to anchor_date do
      attention_items = Dashboards::AttentionQuery.call(user: user)

      inbox_item = attention_items.find { |i| i.kind == :inbox_review }
      expect(inbox_item).to be_present
      expect(inbox_item.title).to eq("4 imported transactions need review")

      import_item = attention_items.find { |i| i.kind == :import_failed }
      expect(import_item).to be_present
      expect(import_item.title).to eq("A statement upload failed to process")

      overdue_item = attention_items.find { |i| i.kind == :balance_due }
      expect(overdue_item).to be_present
      expect(overdue_item.title).to include("Homer Simpson")
      expect(overdue_item.title).to include("overdue")

      schedule_e_item = attention_items.find { |i| i.kind == :schedule_e_review }
      expect(schedule_e_item).to be_present
      expect(schedule_e_item.title).to eq("2 properties are not ready for Schedule E")
      expect(schedule_e_item.description).to include("2025 tax year")
      expect(schedule_e_item.description).to include("1 property needs a tax profile")
      expect(schedule_e_item.description).to include("1 item needs review")
    end

    # 5. Provenance of confirmed imported transactions
    confirmed_txs = user.imported_transactions.confirmed
    expect(confirmed_txs.count).to eq(2)

    tricia_tx = confirmed_txs.find_by!(payer_name: "Tricia McMillan")
    expect(tricia_tx.source_document.attachment_filename).to eq("chase_checking_oct_2025.csv")
    expect(tricia_tx.occurred_on).to eq(Date.new(2025, 10, 2))
    expect(tricia_tx.amount_cents).to eq(240_000)
    expect(tricia_tx.confirmed_source).to eq(Receipt.find_by!(external_reference: "VEN-TRIL-202510"))

    arthur_tx = confirmed_txs.find_by!(payer_name: "Arthur Dent")
    expect(arthur_tx.source_document.attachment_filename).to eq("chase_checking_oct_2025.csv")
    expect(arthur_tx.occurred_on).to eq(Date.new(2025, 10, 2))
    expect(arthur_tx.amount_cents).to eq(220_000)
    expect(arthur_tx.confirmed_source).to eq(Receipt.find_by!(external_reference: "ZEL-DENT-202510"))
  end

  it "executes idempotently and preserves demonstration states as calendar dates advance" do
    travel_to anchor_date do
      expect { load Rails.root.join("db/seeds.rb") }.not_to raise_error
    end
    verify_demonstration_states!(anchor_date)

    # Same moment rerun
    travel_to anchor_date do
      expect { load Rails.root.join("db/seeds.rb") }.not_to raise_error
    end
    verify_demonstration_states!(anchor_date)

    # Advance by 1 day and rerun
    travel_to(anchor_date + 1.day) do
      expect { load Rails.root.join("db/seeds.rb") }.not_to raise_error
    end
    verify_demonstration_states!(anchor_date)

    # Advance by 1 year across calendar year boundary and rerun
    travel_to(anchor_date + 1.year) do
      expect { load Rails.root.join("db/seeds.rb") }.not_to raise_error
    end
    verify_demonstration_states!(anchor_date)
  end
end
