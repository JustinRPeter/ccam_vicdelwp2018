
! This module interfaces aerosol schemes with CCAM

! Currently, only LDR aerosols are supported.  However, the xtg arrays should be moved to
! here in the future, so that there is a common interface for advection and outcdf.

! - This subroutine assumes only one month at a time is integrated in RCM mode.

module aerointerface

implicit none

private
public load_aerosolldr,aerocalc,aerodrop
public ppfprec,ppfmelt,ppfsnow,ppfconv,ppfevap,ppfsubl,pplambs,ppmrate, &
       ppmaccr,ppfstay,ppqfsed,pprscav
public opticaldepth

real, dimension(:,:,:), allocatable, save :: oxidantprev
real, dimension(:,:,:), allocatable, save :: oxidantnow
real, dimension(:,:,:), allocatable, save :: oxidantnext
real, dimension(:), allocatable, save :: rlev,zdayfac
real, dimension(:,:,:), allocatable, save :: opticaldepth
real, dimension(:,:), allocatable, save :: ppfprec,ppfmelt,ppfsnow,ppfconv  ! data saved from LDR cloud scheme
real, dimension(:,:), allocatable, save :: ppfevap,ppfsubl,pplambs,ppmrate  ! data saved from LDR cloud scheme
real, dimension(:,:), allocatable, save :: ppmaccr,ppfstay,ppqfsed,pprscav  ! data saved from LDR cloud scheme
integer, save :: ilon,ilat,ilev
integer, parameter :: naerofamilies = 4      ! Number of aerosol families
real, parameter :: wlc = 0.2e-3         ! LWC of deep conv cloud (kg/m**3)

contains

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Load aerosols emissions from netcdf
subroutine load_aerosolldr(aerofile,oxidantfile,kdatein)
      
use aerosolldr
use cc_mpi
use infile
use ozoneread
      
implicit none

include 'newmpar.h'
include 'parmgeom.h'
      
integer, intent(in) :: kdatein
integer ncstatus,ncid,i,j,varid,tilg
integer ierr,jyear,jmonth
integer, dimension(2) :: spos,npos
integer, dimension(3) :: idum
integer, dimension(4) :: sposs,nposs
real, dimension(:), allocatable, save :: dumg
real, dimension(ifull) :: duma
real, dimension(:,:,:,:), allocatable, save :: oxidantdum
real, dimension(:), allocatable, save :: rlon,rlat
real tlat,tlon,tschmidt
character(len=*), intent(in) :: aerofile,oxidantfile
logical tst
real, parameter :: iotol=1.E-5 ! tolarance for iotest

if (myid==0) write(6,*) "Initialising prognostic aerosols"

allocate(ppfprec(ifull,kl),ppfmelt(ifull,kl))
allocate(ppfsnow(ifull,kl),ppfconv(ifull,kl))
allocate(ppfevap(ifull,kl),ppfsubl(ifull,kl))
allocate(pplambs(ifull,kl),ppmrate(ifull,kl))
allocate(ppmaccr(ifull,kl),ppfstay(ifull,kl))
allocate(ppqfsed(ifull,kl),pprscav(ifull,kl))
allocate(zdayfac(ifull))
allocate(opticaldepth(ifull,naerofamilies,3))
ppfprec=0.
ppfmelt=0.
ppfsnow=0.
ppfconv=0.
ppfevap=0.
ppfsubl=0.
pplambs=0.
ppmrate=0.
ppmaccr=0.
ppfstay=0.
ppqfsed=0.
pprscav=0.
zdayfac=0.
opticaldepth=0.

call aldrinit(ifull,iextra,kl)

if (myid==0) then
  allocate(dumg(ifull_g))
  write(6,*) "Reading ",trim(aerofile)
  call ccnf_open(aerofile,ncid,ncstatus)
  call ncmsg('Aerosol emissions',ncstatus)
  ! check dimensions and location
  call ccnf_get_attg(ncid,'lat0',tlat)
  call ccnf_get_attg(ncid,'lon0',tlon)
  call ccnf_get_attg(ncid,'schmidt0',tschmidt)
  if (abs(rlong0-tlon)>iotol.or.abs(rlat0-tlat)>iotol.or.abs(schmidt-tschmidt)>iotol) then
    write(6,*) "ERROR: Grid mismatch for ",trim(aerofile)
    write(6,*) "rlong0,rlat0,schmidt ",rlong0,rlat0,schmidt
    write(6,*) "tlon,tlat,tschmidt   ",tlon,tlat,tschmidt
    call ccmpi_abort(-1)
  end if
  call ccnf_inq_dimlen(ncid,'longitude',tilg)
  if (tilg/=il_g) then
    write (6,*) "ERROR: Grid mismatch for ",trim(aerofile)
    write (6,*) "il_g,tilg ",il_g,tilg
    call ccmpi_abort(-1)
  end if
  ! load emission fields
  spos=1
  npos(1)=il_g
  npos(2)=il_g*6
  write(6,*) "Loading emissions for SO2 anth l1"
  call ccnf_inq_varid(ncid,'so2a1',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate so2a1"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(1,duma)
  write(6,*) "Loading emissions for SO2 anth l2"
  call ccnf_inq_varid(ncid,'so2a2',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate so2a2"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(2,duma)
  write(6,*) "Loading emissions for BC anth l1"
  call ccnf_inq_varid(ncid,'bca1',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate bca1"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(3,duma)
  write(6,*) "Loading emissions for BC anth l2"
  call ccnf_inq_varid(ncid,'bca2',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate bca2"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(4,duma)
  write(6,*) "Loading emissions for OC anth l1"
  call ccnf_inq_varid(ncid,'oca1',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate oca1"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(5,duma)
  write(6,*) "Loading emissions for OC anth l2"
  call ccnf_inq_varid(ncid,'oca2',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate oca2"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(6,duma)
  write(6,*) "Loading emissions for SO2 bio l1"
  call ccnf_inq_varid(ncid,'so2b1',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate so2b1"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(7,duma)
  write(6,*) "Loading emissions for SO2 bio l2"
  call ccnf_inq_varid(ncid,'so2b2',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate so2b2"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(8,duma)
  write(6,*) "Loading emissions for BC bio l1"
  call ccnf_inq_varid(ncid,'bcb1',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate bcb1"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(9,duma)
  write(6,*) "Loading emissions for BC bio l2"
  call ccnf_inq_varid(ncid,'bcb2',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate bcb2"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(10,duma)
  write(6,*) "Loading emissions for OC bio l1"
  call ccnf_inq_varid(ncid,'ocb1',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate ocb1"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(11,duma)
  write(6,*) "Loading emissions for OC bio l2"
  call ccnf_inq_varid(ncid,'ocb2',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate ocb2"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(12,duma)
  write(6,*) "Loading emissions for DMS ocean"
  call ccnf_inq_varid(ncid,'dmso',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate dmso"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(13,duma)
  write(6,*) "Loading emissions for DMS land"
  call ccnf_inq_varid(ncid,'dmst',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate dmst"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(14,duma)
  write(6,*) "Loading emissions for natural organic"
  call ccnf_inq_varid(ncid,'ocna',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate ocna"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(15,duma)
  write(6,*) "Loading emissions for Volcanic SO2"
  call ccnf_inq_varid(ncid,'vso2',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate vso2"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloademiss(16,duma)
  ! load dust fields
  write(6,*) "Loading emissions for dust (sand)"
  call ccnf_inq_varid(ncid,'sandem',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate sandem"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloaderod(1,1,duma)
  write(6,*) "Loading emissions for dust (slit)"
  call ccnf_inq_varid(ncid,'siltem',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate siltem"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloaderod(2,1,duma)
  write(6,*) "Loading emissions for dust (clay)"
  call ccnf_inq_varid(ncid,'clayem',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate clayem"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,spos,npos,dumg)
  call ccmpi_distribute(duma,dumg)
  call aldrloaderod(3,1,duma)
  call ccnf_close(ncid)
  deallocate(dumg)
  ! load oxidant fields
  write(6,*) "Reading ",trim(oxidantfile)
  call ccnf_open(oxidantfile,ncid,ncstatus)
  call ncmsg('Oxidants',ncstatus)
  ! check dimensions and location
  call ccnf_inq_dimlen(ncid,'lon',ilon)
  call ccnf_inq_dimlen(ncid,'lat',ilat)
  call ccnf_inq_dimlen(ncid,'lev',ilev)
  write(6,*) "Found oxidant dimensions ",ilon,ilat,ilev
  idum(1)=ilon
  idum(2)=ilat
  idum(3)=ilev
  call ccmpi_bcast(idum(1:3),0,comm_world)
  allocate(oxidantprev(ifull,ilev,4))
  allocate(oxidantnow(ifull,ilev,4))
  allocate(oxidantnext(ifull,ilev,4))
  allocate(rlon(ilon),rlat(ilat),rlev(ilev))
  allocate(oxidantdum(ilon,ilat,ilev,3))
  sposs=1
  nposs(1)=ilon
  nposs(2)=ilat
  nposs(3)=ilev
  nposs(4)=1
  ! use kdate_s as kdate has not yet been defined
  jyear=kdatein/10000
  jmonth=(kdatein-jyear*10000)/100
  write(6,*) "Processing oxidant file for month ",jmonth
  call ccnf_inq_varid(ncid,'lon',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate lon"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,sposs(1:1),nposs(1:1),rlon)
  call ccnf_inq_varid(ncid,'lat',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate lat"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,sposs(2:2),nposs(2:2),rlat) ! input latitudes (deg)
  call ccnf_inq_varid(ncid,'lev',varid,tst)
  if (tst) then
    write(6,*) "ERROR: Cannot locate lev"
    call ccmpi_abort(-1)
  end if
  call ccnf_get_vara(ncid,varid,sposs(3:3),nposs(3:3),rlev) ! input vertical levels
  call ccmpi_bcast(rlon,0,comm_world)
  call ccmpi_bcast(rlat,0,comm_world)
  call ccmpi_bcast(rlev,0,comm_world)
  do j=1,4
    select case(j)
      case(1)
        write(6,*) "Reading OH"
        call ccnf_inq_varid(ncid,'OH',varid,tst)
        if (tst) then
          write(6,*) "ERROR: Cannot locate OH"
          call ccmpi_abort(-1)
        end if
      case(2)
        write(6,*) "Reading H2O2"
        call ccnf_inq_varid(ncid,'H2O2',varid,tst)
        if (tst) then
          write(6,*) "ERROR: Cannot locate H2O2"
          call ccmpi_abort(-1)
        end if
      case(3)
        write(6,*) "Reading O3"
        call ccnf_inq_varid(ncid,'O3',varid,tst)
        if (tst) then
          write(6,*) "ERROR: Cannot locate O3"
          call ccmpi_abort(-1)
        end if
      case(4)
        write(6,*) "Reading NO2"
        call ccnf_inq_varid(ncid,'NO2',varid,tst)
        if (tst) then
          write(6,*) "ERROR: Cannot locate NO2"
          call ccmpi_abort(-1)
        end if
    end select
    do i=1,3
      select case(i)
        case(1)
          sposs(4)=jmonth-1
          if (sposs(4)<1) sposs(4)=12
          call ccnf_get_vara(ncid,varid,sposs,nposs,oxidantdum(:,:,:,1))
          call ccmpi_bcast(oxidantdum(:,:,:,1),0,comm_world)
        case(2)
          sposs(4)=jmonth
          call ccnf_get_vara(ncid,varid,sposs,nposs,oxidantdum(:,:,:,2))
          call ccmpi_bcast(oxidantdum(:,:,:,2),0,comm_world)
        case(3)
          sposs(4)=jmonth+1
          if (sposs(4)>12) sposs(4)=1
          call ccnf_get_vara(ncid,varid,sposs,nposs,oxidantdum(:,:,:,3))
          call ccmpi_bcast(oxidantdum(:,:,:,3),0,comm_world)
      end select
    end do
    call o3regrid(oxidantprev(:,:,j),oxidantnow(:,:,j),oxidantnext(:,:,j),oxidantdum,rlon,rlat,ilon,ilat,ilev)
  end do
  call ccnf_close(ncid)
  deallocate(oxidantdum,rlat,rlon)
else
  ! load emission fields
  do i=1,16
    call ccmpi_distribute(duma)
    call aldrloademiss(i,duma)
  end do
  ! load dust fields
  do i=1,3
    call ccmpi_distribute(duma)
    call aldrloaderod(i,1,duma)
  end do
  ! load oxidant fields
  call ccmpi_bcast(idum(1:3),0,comm_world)
  ilon=idum(1)
  ilat=idum(2)
  ilev=idum(3)
  allocate(oxidantprev(ifull,ilev,4))
  allocate(oxidantnow(ifull,ilev,4))
  allocate(oxidantnext(ifull,ilev,4))
  allocate(rlon(ilon),rlat(ilat),rlev(ilev))
  allocate(oxidantdum(ilon,ilat,ilev,3))
  call ccmpi_bcast(rlon,0,comm_world)
  call ccmpi_bcast(rlat,0,comm_world)
  call ccmpi_bcast(rlev,0,comm_world)
  do j=1,4
    do i=1,3
      call ccmpi_bcast(oxidantdum(:,:,:,i),0,comm_world)
    end do
    call o3regrid(oxidantprev(:,:,j),oxidantnow(:,:,j),oxidantnext(:,:,j),oxidantdum,rlon,rlat,ilon,ilat,ilev)    
  end do
  deallocate(oxidantdum,rlat,rlon)
end if

return
end subroutine load_aerosolldr

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Update prognostic aerosols
subroutine aerocalc

use aerosolldr
use arrays_m
use cfrac_m
use extraout_m
use infile
use kuocomb_m
use latlong_m
use liqwpar_m
use map_m
use morepbl_m
use nharrs_m
use nsibd_m
use ozoneread
use pbl_m
use screen_m
use sigs_m
use soil_m
use soilsnow_m
use vegpar_m
use work2_m
use zenith_m

implicit none

include 'newmpar.h'
include 'const_phys.h'
include 'kuocom.h'
include 'parm.h'
include 'soilv.h'

integer jyear,jmonth,jday,jhour,jmin,mins,smins
integer j,k,tt,ttx,iq
integer, save :: sday=-9999
real dhr,fjd,sfjd,r1,dlt,alp,slag
real, dimension(ifull) :: coszro,taudar
real, dimension(ifull,kl) :: oxout,zg,clcon,pccw,rhoa
real, dimension(ifull,kl) :: tnhs,dz,ctmp
real, dimension(ifull,kl) :: dumt,dumql,dumqf
real, dimension(ifull,kl,naero) :: xtusav
real, dimension(ifull) :: dxy,cldcon,wg
real, dimension(kl+1) :: sigh

! timer calculations
call getzinp(fjd,jyear,jmonth,jday,jhour,jmin,mins)
! update prescribed oxidant fields once per day
if (sday<=mins-1440) then
  sday=mins
  do j=1,4      
    call fieldinterpolate(oxout,oxidantprev(:,:,j),oxidantnow(:,:,j),oxidantnext(:,:,j), &
                          rlev,ifull,kl,ilon,ilat,ilev,mins,sig,ps)
    do k=1,kl
      call aldrloadoxidant(k+(j-1)*kl,oxout(:,k))
    end do
  end do
  ! estimate day length (presumably to preturb day-time OH levels)
  dhr=dt/3600.
  ttx=nint(86400./dt)
  zdayfac(:)=0.
  do tt=1,ttx ! we seem to get a different answer if dhr=24. and ttx=1.
    smins=int(real(tt-1)*dt/60.)+mins
    sfjd=float(mod(smins,525600))/1440.  ! 525600 = 1440*365
    call solargh(sfjd,bpyear,r1,dlt,alp,slag)
    call zenith(sfjd,r1,dlt,slag,rlatt,rlongg,dhr,ifull,coszro,taudar)
    zdayfac(:)=zdayfac(:)+taudar
  end do
  where (zdayfac>0.)
    zdayfac(:)=real(ttx)/zdayfac(:)
  end where
end if

! set-up input data fields ------------------------------------------------
sigh(1:kl) = sigmh(1:kl) ! store half-levels
sigh(kl+1) = 0.

! Non-hydrostatic terms
tnhs(:,1)=phi_nh(:,1)/bet(1)
do k=2,kl
  ! representing non-hydrostatic term as a correction to air temperature
  tnhs(:,k)=(phi_nh(:,k)-phi_nh(:,k-1)-betm(k)*tnhs(:,k-1))/bet(k)
end do

zg(:,1)=bet(1)*t(1:ifull,1)/grav
do k=2,kl
  zg(:,k)=zg(:,k-1)+(bet(k)*t(1:ifull,k)+betm(k)*t(1:ifull,k-1))/grav ! height above surface in meters
end do
zg=zg+phi_nh/grav
do k=1,kl
  dz(:,k)=-rdry*dsig(k)*(t(1:ifull,k)+tnhs(:,k))/(grav*sig(k))
end do
dxy=ds*ds/(em*em)       ! grid spacing in m**2
do k=1,kl
  rhoa(:,k)=ps*sig(k)/(rdry*t(1:ifull,k)) !density of air (kg/m**3)
end do

! estimate convective cloud fraction
! from leoncld.f
where (ktsav<kl-1)
  cldcon=min(acon+bcon*log(1.+condc*86400./dt),0.8) !NCAR
elsewhere
  cldcon=0.
end where
if (nmr>=1) then
  do iq=1,ifull
    do k=1,kbsav(iq)
      clcon(iq,k)=0.
      pccw(iq,kl+1-k)=0.
    end do
    do k=kbsav(iq)+1,ktsav(iq)
      clcon(iq,k)=cldcon(iq) ! maximum overlap
      pccw(iq,kl+1-k)=wlc/rhoa(iq,k)
    end do
    do k=ktsav(iq)+1,kl
      clcon(iq,k)=0.
      pccw(iq,kl+1-k)=0.
    end do
  end do  
else
  do iq=1,ifull
    do k=1,kbsav(iq)
      clcon(iq,k)=0.
      pccw(iq,kl+1-k)=0.
    end do
    do k=kbsav(iq)+1,ktsav(iq)
      clcon(iq,k)=1.-(1.-cldcon(iq))**(1./real(ktsav(iq)-kbsav(iq)+2)) !Random overlap
      pccw(iq,kl+1-k)=wlc/rhoa(iq,k)
    end do
    do k=ktsav(iq)+1,kl
      clcon(iq,k)=0.
      pccw(iq,kl+1-k)=0.
    end do
  end do  
end if

! Convert from aerosol concentration outside convective cloud (used by CCAM)
! to aerosol concentration inside convective cloud
ctmp=max(clcon,1.E-6)
do j=1,naero
  xtusav(:,:,j)=(xtg(1:ifull,:,j)-(1.-ctmp)*xtosav(:,:,j))/ctmp
end do

wg=min(max(wetfac,0.),1.)

! update prognostic aerosols
dumt=t(1:ifull,:)
dumql=qlg(1:ifull,:)
dumqf=qfg(1:ifull,:)
call aldrcalc(dt,sig,sigh,dsig,zg,dz,cansto,fwet,wg,pblh,ps,   &
              tss,dumt,condx,condc,snowd,sgsave,fg,            &
              eg,u10,ustar,zo,land,fracice,sigmf,              &
              dumql,dumqf,cfrac,clcon,                         &
              pccw,dxy,rhoa,cdtq,ppfprec,ppfmelt,ppfsnow,      &
              ppfconv,ppfevap,ppfsubl,pplambs,ppmrate,         &
              ppmaccr,ppfstay,ppqfsed,pprscav,zdayfac,xtusav)

! store sulfate for LH+SF radiation scheme.  SEA-ESF radiation scheme imports prognostic aerosols in seaesfrad.f90.
! Factor 1.e3 to convert to g/m2, x 3 to get sulfate from sulfur
so4t(:)=0.
do k=1,kl
  so4t(:)=so4t(:)+1.e3*xtg(:,k,3)*(-ps(:)*dsig(k))/grav
enddo

return
end subroutine aerocalc

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Estimate cloud droplet size
subroutine aerodrop(iaero,istart,imax,kl,cdn,rhoa,land,rlatt,outconv)

use aerosolldr

implicit none

include 'const_phys.h'
include 'cparams.h'

integer, intent(in) :: iaero,istart,imax,kl
integer k
real, dimension(imax,kl), intent(out) :: cdn
real, dimension(imax,kl), intent(in) :: rhoa
real, dimension(imax), intent(in) :: rlatt
logical, dimension(imax), intent(in) :: land
logical, intent(in), optional :: outconv
logical convmode

convmode=.true.
if (present(outconv)) then
  convmode=.not.outconv
end if

select case(abs(iaero))
  case(2)
    call cldrop(istart,imax,cdn,rhoa,convmode)
  case default
    where (land(:).and.rlatt(:)>0.)
      cdn(:,1)=cdropl_nh
    else where (land(:))
      cdn(:,1)=cdropl_sh
    else where (rlatt(:)>0.)
      cdn(:,1)=cdrops_nh
    else where
      cdn(:,1)=cdrops_sh
    end where
    do k=2,kl
      cdn(:,k)=cdn(:,1)
    enddo
end select

return
end subroutine aerodrop

end module aerointerface
