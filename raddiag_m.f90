! Conformal Cubic Atmospheric Model
    
! Copyright 2015-2019 Commonwealth Scientific Industrial Research Organisation (CSIRO)
    
! This file is part of the Conformal Cubic Atmospheric Model (CCAM)
!
! CCAM is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! CCAM is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with CCAM.  If not, see <http://www.gnu.org/licenses/>.

!------------------------------------------------------------------------------
    
module raddiag_m

implicit none

private
public koundiag, odcalc
public sint_ave,sot_ave,soc_ave,sgn_ave
public sgdn_ave,rgdn_ave,sgdn,rgdn,sgn,rgn
public rtu_ave,rtc_ave,rgn_ave,rgc_ave,sgc_ave
public cld_ave,cll_ave,clm_ave,clh_ave
public sunhours,fbeam
public raddiag_init,raddiag_end
public sw_tend, lw_tend

integer, save :: koundiag = 0
real, dimension(:), allocatable, save :: sint_ave,sot_ave,soc_ave,sgn_ave
real, dimension(:), allocatable, save :: sgdn_ave,rgdn_ave,sgdn,rgdn,sgn,rgn
real, dimension(:), allocatable, save :: rtu_ave,rtc_ave,rgn_ave,rgc_ave,sgc_ave
real, dimension(:), allocatable, save :: cld_ave,cll_ave,clm_ave,clh_ave
real, dimension(:), allocatable, save :: sunhours,fbeam
real, dimension(:,:), allocatable, save :: sw_tend, lw_tend
logical, save :: odcalc = .false.

contains

subroutine raddiag_init(ifull,kl)

implicit none

integer, intent(in) :: ifull,kl

allocate(sint_ave(ifull),sot_ave(ifull),soc_ave(ifull),sgn_ave(ifull))
allocate(sgdn_ave(ifull),rgdn_ave(ifull),sgdn(ifull),rgdn(ifull),sgn(ifull),rgn(ifull))
allocate(rtu_ave(ifull),rtc_ave(ifull),rgn_ave(ifull),rgc_ave(ifull),sgc_ave(ifull))
allocate(cld_ave(ifull),cll_ave(ifull),clm_ave(ifull),clh_ave(ifull))
allocate(sunhours(ifull),fbeam(ifull))
allocate(sw_tend(ifull,kl),lw_tend(ifull,kl))

! needs to be initialised here for zeroth time-step in outcdf.f90
sint_ave=0.
sot_ave=0.
soc_ave=0.
sgn_ave=0.
sgdn_ave=0.
rgdn_ave=0.
sgdn=0.
rgdn=0.
sgn=0.
rgn=0.
rtu_ave=0.
rtc_ave=0.
rgn_ave=0.
rgc_ave=0.
sgc_ave=0.
cld_ave=0.
cll_ave=0.
clm_ave=0.
clh_ave=0.
sunhours=0.
fbeam=0.
sw_tend=0.
lw_tend=0.

return
end subroutine raddiag_init

subroutine raddiag_end

implicit none

deallocate(sint_ave,sot_ave,soc_ave,sgn_ave)
deallocate(sgdn_ave,rgdn_ave,sgdn,rgdn,sgn,rgn)
deallocate(rtu_ave,rtc_ave,rgn_ave,rgc_ave,sgc_ave)
deallocate(cld_ave,cll_ave,clm_ave,clh_ave)
deallocate(sunhours,fbeam)
deallocate(sw_tend,lw_tend)

return
end subroutine raddiag_end

end module raddiag_m