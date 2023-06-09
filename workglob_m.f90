module workglob_m

implicit none

private
public rlong4,rlat4
public rlong4_l,rlat4_l
public workglob_init,workglob_end
public worklocl_init,worklocl_end

real, dimension(:,:), allocatable, save :: rlong4,rlat4
real, dimension(:,:), allocatable, save :: rlong4_l,rlat4_l

contains

subroutine workglob_init(ifull_g)

implicit none

integer, intent(in) :: ifull_g

if (.not.allocated(rlong4)) then
 allocate(rlong4(ifull_g,4),rlat4(ifull_g,4))
end if

return
end subroutine workglob_init

subroutine workglob_end

implicit none

deallocate(rlong4,rlat4)

return
end subroutine workglob_end

subroutine worklocl_init(ifull)

implicit none

integer, intent(in) :: ifull

if (.not.allocated(rlong4_l)) then
  allocate(rlong4_l(ifull,4),rlat4_l(ifull,4))
end if

return
end subroutine worklocl_init

subroutine worklocl_end

implicit none

deallocate(rlong4_l,rlat4_l)

return
end subroutine worklocl_end

end module workglob_m