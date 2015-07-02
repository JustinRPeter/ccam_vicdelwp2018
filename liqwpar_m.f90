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
    
module liqwpar_m

implicit none

private
public ifullw,qlg,qfg ! liquid water, ice water
public qrg !,qsg,qgrau ! rain, snow, graupel
public liqwpar_init,liqwpar_end

integer, save :: ifullw
real, dimension(:,:), allocatable, save :: qlg,qfg
real, dimension(:,:), allocatable, save :: qrg !,qsg
!real, dimension(:,:), allocatable, save :: qgrau

contains

subroutine liqwpar_init(ifull,iextra,kl)

implicit none

integer, intent(in) :: ifull,iextra,kl

allocate(qlg(ifull+iextra,kl),qfg(ifull+iextra,kl))
allocate(qrg(ifull+iextra,kl)) !,qsg(ifull+iextra,kl))
!allocate(qgrau(ifull+iextra,kl))
ifullw=ifull
qlg=0.
qfg=0.
qrg=0.
!qsg=0.
!qgrau=0.

return
end subroutine liqwpar_init

subroutine liqwpar_end

implicit none

deallocate(qlg,qfg)
deallocate(qrg) !,qsg)
!deallocate(qgrau)

return
end subroutine liqwpar_end

end module liqwpar_m