# frozen_string_literal: true

require "rails_helper"

RSpec.describe "db/seeds.rb" do
  include ActiveSupport::Testing::TimeHelpers

  after(:all) do
    ActiveRecord::Tasks::DatabaseTasks.truncate_all
  end

  it "executes idempotently and reruns cleanly as calendar dates advance" do
    expect { load Rails.root.join("db/seeds.rb") }.not_to raise_error

    expect(Property.count).to eq(4)
    expect(RentableUnit.count).to eq(7)
    expect(Tenancy.count).to eq(7)

    # Same moment rerun
    expect { load Rails.root.join("db/seeds.rb") }.not_to raise_error
    expect(Property.count).to eq(4)
    expect(RentableUnit.count).to eq(7)
    expect(Tenancy.count).to eq(7)

    # Advance by 1 day
    travel 1.day do
      expect { load Rails.root.join("db/seeds.rb") }.not_to raise_error
      expect(Property.count).to eq(4)
      expect(RentableUnit.count).to eq(7)
      expect(Tenancy.count).to eq(7)
    end

    # Advance by 1 year across calendar year boundary
    travel 1.year do
      expect { load Rails.root.join("db/seeds.rb") }.not_to raise_error
      expect(Property.count).to eq(4)
      expect(RentableUnit.count).to eq(7)
      expect(Tenancy.count).to eq(7)
    end
  end
end
