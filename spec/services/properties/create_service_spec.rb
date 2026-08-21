require "rails_helper"

RSpec.describe Properties::CreateService do
  let(:user) { create(:user) }

  describe ".call" do
    context "with valid property attributes and no explicit unit" do
      let(:params) do
        {
          address: "742 Evergreen Terrace",
          asset_type: "single_family",
          square_footage: 2200
        }
      end

      it "creates a property and an implicit Main Unit atomically" do
        result = nil
        expect {
          result = described_class.call(user: user, params: params)
        }.to change(Property, :count).by(1)
         .and change(RentableUnit, :count).by(1)

        expect(result).to be_success
        property = result.value!.data[:property]
        expect(property.address).to eq("742 Evergreen Terrace")
        expect(property.asset_type).to eq("single_family")
        expect(property.square_footage).to eq(2200)

        main_unit = property.rentable_units.first
        expect(main_unit.name).to eq("Main Unit")
        expect(main_unit.unit_identifier).to be_nil
        expect(main_unit.square_footage).to eq(2200)
        expect(main_unit.active).to be true
      end
    end

    context "with valid property attributes and explicit unit attributes" do
      let(:params) do
        {
          address: "100 Elm St",
          asset_type: "multifamily",
          square_footage: 4000,
          unit: {
            name: "Unit 1A",
            unit_identifier: "1A",
            square_footage: 1000
          }
        }
      end

      it "creates the property with the specified custom unit" do
        result = described_class.call(user: user, params: params)

        expect(result).to be_success
        property = result.value!.data[:property]
        expect(property.rentable_units.count).to eq(1)

        unit = property.rentable_units.first
        expect(unit.name).to eq("Unit 1A")
        expect(unit.unit_identifier).to eq("1A")
        expect(unit.square_footage).to eq(1000)
      end
    end

    context "with explicit property_params and unit_params arguments" do
      it "creates property with unit_params without name falling back to main unit" do
        result = described_class.call(
          user: user,
          property_params: { address: "200 Oak St", asset_type: "single_family" },
          unit_params: { name: "", square_footage: 1200 }
        )
        expect(result).to be_success
        property = result.value!.data[:property]
        expect(property.rentable_units.first.name).to eq("Main Unit")
      end

      it "handles record invalid when property address is blank" do
        result = described_class.call(
          user: user,
          property_params: { address: "", asset_type: "single_family" }
        )
        expect(result).to be_failure
        expect(result.failure.error).to include("Address can't be blank")
      end
    end

    context "with invalid property parameters" do
      let(:params) do
        {
          address: "",
          asset_type: "invalid_type"
        }
      end

      it "returns a failure result and does not create property or units" do
        result = nil
        expect {
          result = described_class.call(user: user, params: params)
        }.not_to change(Property, :count)

        expect(result).to be_failure
        expect(result.failure.data[:property]).to be_present
        expect(result.failure.data[:property].errors[:asset_type]).to be_present
      end
    end
  end
end
