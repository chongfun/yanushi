module Properties
  class CreateService
    def self.call(user:, property_params: nil, unit_params: nil, params: nil)
      p_params = (property_params || params || {}).to_h.symbolize_keys
      u_params = (unit_params || p_params.delete(:unit) || {}).to_h.symbolize_keys
      new(user: user, property_params: p_params, unit_params: u_params).call
    end

    def initialize(user:, property_params:, unit_params: nil)
      @user = user
      @property_params = property_params
      @unit_params = unit_params
    end

    def call
      property = nil
      begin
        property = user.properties.new(property_params)
      rescue ArgumentError => e
        property = user.properties.new(property_params.except(:asset_type))
        property.valid?
        property.errors.add(:asset_type, "is invalid")
        return ServiceResult.failure(data: { property: property }, error: e.message, code: :validation_error)
      end

      Property.transaction do
        property.save!

        if unit_params.present? && unit_params[:name].present?
          property.rentable_units.create!(unit_params)
        else
          property.rentable_units.create!(name: "Main Unit", square_footage: property.square_footage, active: true)
        end
      end

      ServiceResult.success({ property: property })
    rescue ActiveRecord::RecordInvalid => e
      failed_record = e.record || property
      ServiceResult.failure(data: { property: property }, error: failed_record.errors.full_messages.to_sentence, code: :validation_error)
    end

    private

      attr_reader :user, :property_params, :unit_params
  end
end
