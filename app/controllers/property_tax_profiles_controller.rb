class PropertyTaxProfilesController < ApplicationController
  before_action :set_property
  before_action :set_tax_profile, only: %i[edit update]

  def new
    year = params[:tax_year].presence ? params[:tax_year].to_i : Date.current.year
    @tax_profile = @property.tax_profiles.build(
      tax_year: year,
      schedule_e_property_type: default_schedule_e_type
    )
  end

  def create
    @tax_profile = @property.tax_profiles.build(tax_profile_params)

    if @tax_profile.save
      redirect_to schedule_e_property_path(@property, year: @tax_profile.tax_year),
                  notice: "Tax classification for #{@tax_profile.tax_year} was successfully configured."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @tax_profile.update(tax_profile_params)
      redirect_to schedule_e_property_path(@property, year: @tax_profile.tax_year),
                  notice: "Tax classification for #{@tax_profile.tax_year} was successfully updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

    def set_property
      @property = authenticated_user.properties.find(params[:property_id])
    end

    def set_tax_profile
      @tax_profile = @property.tax_profiles.find(params[:id])
    end

    def tax_profile_params
      params.require(:property_tax_profile).permit(
        :tax_year,
        :schedule_e_property_type,
        :other_description
      )
    end

    def default_schedule_e_type
      case @property.asset_type.to_s
      when "single_family" then "single_family_residence"
      when "multifamily" then "multi_family_residence"
      when "commercial" then "commercial"
      when "land" then "land"
      else "single_family_residence"
      end
    end
end
