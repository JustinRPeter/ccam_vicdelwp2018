module histave_m

implicit none

private
public eg_ave,fg_ave,ga_ave,epan_ave,dew_ave
public cbas_ave,ctop_ave,rndmax,qscrn_ave
public tmaxscr,tminscr,tscr_ave
public rhmaxscr,rhminscr
public riwp_ave,rlwp_ave,u10max,v10max,u10mx
public u1max,v1max,u2max,v2max,capemax,epot_ave
public rnet_ave,mixdep_ave
public wb_ave,tsu_ave,alb_ave,fbeam_ave,psl_ave
public fpn_ave,frs_ave,frp_ave
!public tgg_ave
public histave_init,histave_end

real, dimension(:), allocatable, save :: eg_ave,fg_ave,ga_ave,epan_ave,dew_ave
real, dimension(:), allocatable, save :: cbas_ave,ctop_ave,rndmax,qscrn_ave
real, dimension(:), allocatable, save :: tmaxscr,tminscr,tscr_ave
real, dimension(:), allocatable, save :: rhmaxscr,rhminscr
real, dimension(:), allocatable, save :: riwp_ave,rlwp_ave,u10max,v10max,u10mx
real, dimension(:), allocatable, save :: u1max,v1max,u2max,v2max,capemax,epot_ave
real, dimension(:), allocatable, save :: rnet_ave,mixdep_ave
real, dimension(:,:), allocatable, save :: wb_ave
real, dimension(:), allocatable, save :: tsu_ave,alb_ave,fbeam_ave,psl_ave
real, dimension(:), allocatable, save :: fpn_ave,frs_ave,frp_ave
!real, dimension(:,:), allocatable, save :: tgg_ave

contains

subroutine histave_init(ifull,iextra,kl,ms)

implicit none

integer, intent(in) :: ifull,iextra,kl,ms

allocate(eg_ave(ifull),fg_ave(ifull),ga_ave(ifull),epan_ave(ifull),dew_ave(ifull))
allocate(cbas_ave(ifull),ctop_ave(ifull),rndmax(ifull),qscrn_ave(ifull))
allocate(tmaxscr(ifull),tminscr(ifull),tscr_ave(ifull))
allocate(rhmaxscr(ifull),rhminscr(ifull))
allocate(riwp_ave(ifull),rlwp_ave(ifull),u10max(ifull),v10max(ifull),u10mx(ifull))
allocate(u1max(ifull),v1max(ifull),u2max(ifull),v2max(ifull),capemax(ifull),epot_ave(ifull))
allocate(rnet_ave(ifull),mixdep_ave(ifull))
allocate(wb_ave(ifull,ms),tsu_ave(ifull),alb_ave(ifull),fbeam_ave(ifull),psl_ave(ifull))
allocate(fpn_ave(ifull),frs_ave(ifull),frp_ave(ifull))
!allocate(tgg_ave(ifull,ms))

return
end subroutine histave_init

subroutine histave_end

implicit none

deallocate(eg_ave,fg_ave,ga_ave,epan_ave,dew_ave)
deallocate(cbas_ave,ctop_ave,rndmax,qscrn_ave)
deallocate(tmaxscr,tminscr,tscr_ave)
deallocate(rhmaxscr,rhminscr)
deallocate(riwp_ave,rlwp_ave,u10max,v10max,u10mx)
deallocate(u1max,v1max,u2max,v2max,capemax,epot_ave)
deallocate(rnet_ave,mixdep_ave)
deallocate(wb_ave,tsu_ave,alb_ave,fbeam_ave,psl_ave)
deallocate(fpn_ave,frs_ave,frp_ave)
!deallocate(tgg_ave)

return
end subroutine histave_end

end module histave_m