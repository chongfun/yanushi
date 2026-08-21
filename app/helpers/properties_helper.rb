module PropertiesHelper
  def active_tenancy_for(property)
    active_tenancies_for(property).first || property.tenancies.select(&:commencement_date).max_by { |tenancy| tenancy.commencement_date || Date.current }
  end

  def active_tenancies_for(property)
    property.tenancies.select(&:active?)
  end

  def active_lease_for(property)
    active_tenancy_for(property)
  end

  def active_leases_for(property)
    active_tenancies_for(property)
  end
end
