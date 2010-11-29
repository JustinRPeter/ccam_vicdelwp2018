module raddiag_m

implicit none

private
public koundiag
public sint_ave,sot_ave,soc_ave,sgn_ave
public sgdn_ave,rgdn_ave
public rtu_ave,rtc_ave,rgn_ave,rgc_ave
public cld_ave,cll_ave,clm_ave,clh_ave
public raddiag_init,raddiag_end

integer, save :: koundiag
real, dimension(:), allocatable, save :: sint_ave,sot_ave,soc_ave,sgn_ave
real, dimension(:), allocatable, save :: sgdn_ave,rgdn_ave
real, dimension(:), allocatable, save :: rtu_ave,rtc_ave,rgn_ave,rgc_ave
real, dimension(:), allocatable, save :: cld_ave,cll_ave,clm_ave,clh_ave

contains

subroutine raddiag_init(ifull,iextra,kl)

implicit none

integer, intent(in) :: ifull,iextra,kl

allocate(sint_ave(ifull),sot_ave(ifull),soc_ave(ifull),sgn_ave(ifull))
allocate(sgdn_ave(ifull),rgdn_ave(ifull))
allocate(rtu_ave(ifull),rtc_ave(ifull),rgn_ave(ifull),rgc_ave(ifull))
allocate(cld_ave(ifull),cll_ave(ifull),clm_ave(ifull),clh_ave(ifull))

return
end subroutine raddiag_init

subroutine raddiag_end

implicit none

deallocate(sint_ave,sot_ave,soc_ave,sgn_ave)
deallocate(sgdn_ave,rgdn_ave)
deallocate(rtu_ave,rtc_ave,rgn_ave,rgc_ave)
deallocate(cld_ave,cll_ave,clm_ave,clh_ave)

return
end subroutine raddiag_end

end module raddiag_m