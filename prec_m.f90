! Conformal Cubic Atmospheric Model
    
! Copyright 2015 Commonwealth Scientific Industrial Research Organisation (CSIRO)
    
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

module prec_m

implicit none

private
public evap,precip,precc,rnd_3hr,cape
public prec_init,prec_end

real, dimension(:), allocatable, save :: evap
real, dimension(:), allocatable, target, save :: cape, precc, precip
real, dimension(:,:), allocatable, save :: rnd_3hr

contains

subroutine prec_init(ifull)

implicit none

integer, intent(in) :: ifull

allocate(evap(ifull),precip(ifull),precc(ifull),rnd_3hr(ifull,8),cape(ifull))

! needs to be initialised here for zeroth time-step in outcdf.f90
precip(:)    = 0.
precc(:)     = 0.
rnd_3hr(:,:) = 0.

return
end subroutine prec_init

subroutine prec_end

implicit none

deallocate(evap,precip,precc,rnd_3hr,cape)

return
end subroutine prec_end

end module prec_m