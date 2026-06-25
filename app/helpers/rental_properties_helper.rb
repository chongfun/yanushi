module RentalPropertiesHelper
  def active_lease_for(rental_property)
    active_leases_for(rental_property).first || rental_property.leases.select(&:commencement_date).max_by { |lease| lease.commencement_date || Date.current }
  end

  def active_leases_for(rental_property)
    rental_property.leases.select(&:active?)
  end
end
