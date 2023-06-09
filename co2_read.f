!      block data co2_blk
!
!      include 'newmpar.h'
!      include 'rdparm.h'  ! needed before other radiation common blocks
!      include 'co2dta.h'
!
!c   The following coeffiecients don't depend on resolution or CO2 conc.
!      data b0,b1,b2,b3/-.51926410e-4,-.18113332e-3,
!     & -.10680132e-5,-.67303519e-7/
!      end

c******************************************************************************

      subroutine co2_read(sigma,jyear)
c  This routine reads the CO2 transmission coefficients from the
c  co2_datafile (filename set in namelist)
c  was unit 15 for DARLAM, unit 17 for conformal-cubic

      use cc_mpi
      use co2dta_m
      use radisw_m           ! passes rrvco2 to radrive for use in swr89
      
      implicit none
      
      include 'parm.h'
      include 'filnames.h'
      include 'newmpar.h'
      include 'rdparm.h'  ! needed before other radiation common blocks
      
      real, parameter :: sigtol=1e-3
      real sigma(kl), sigin(kl)
      real rcn(35)
      real, dimension(7) :: rdum
      integer, intent(in) :: jyear
      integer k,i,ierr,nlev,iyr
      integer, parameter :: lu=15
      
      !--------------------------------------------------------------
      ! MJT radiation
      if (myid==0) then
        print *,'Radiative data read from file ',trim(radfile)
        open(lu,file=radfile,form='formatted',status='old')
      end if
      if (nrad.eq.5) then
        if (myid==0) then
          nlev=0
          read(lu,*,iostat=ierr) nlev
          if (nlev.gt.0) then ! old format
            read(lu,*) (sigin(1),i=nlev,1,-1)
            read(lu,*) rrvco2
            rrvch4=0.
            rrvn2o=0.
            rrvf11=0.
            rrvf12=0.
            rrvf113=0.
            rrvf22=0.
          else                ! new format
            iyr=-9999
            do while (iyr.lt.jyear)
              read(lu,*,iostat=ierr) iyr,rcn(1:35)
              if (ierr.lt.0) then
                write(6,*) "ERROR: Cannot find concentration data"
                stop
              end if
            end do
            rrvco2=rcn(3)*1.E-6
            rrvch4=rcn(4)*1.E-9
            rrvn2o=rcn(5)*1.E-9
            rrvf11=rcn(20)*1.E-12
            rrvf12=rcn(21)*1.E-12
            rrvf113=rcn(22)*1.E-12
            rrvf22=rcn(27)*1.E-12            
          end if
          write(6,*) ' CO2  mixing ratio is ', rrvco2*1e6,' ppmv'
          write(6,*) ' CH4  mixing ratio is ', rrvch4*1e9,' ppbv'
          write(6,*) ' N2O  mixing ratio is ', rrvn2o*1e9,' ppbv'
          write(6,*) ' F11  mixing ratio is ', rrvf11*1e12,' pptv'
          write(6,*) ' F12  mixing ratio is ', rrvf12*1e12,' pptv'
          write(6,*) ' F113 mixing ratio is ', rrvf113*1e12,' pptv'
          write(6,*) ' F22  mixing ratio is ', rrvf22*1e12,' pptv'
          close(lu)
          rdum(1)=rrvco2
          rdum(2)=rrvch4
          rdum(3)=rrvn2o
          rdum(4)=rrvf11
          rdum(5)=rrvf12
          rdum(6)=rrvf113
          rdum(7)=rrvf22
        end if
        call ccmpi_bcast(rdum(1:7),0,comm_world)
        rrvco2=rdum(1)
        rrvch4=rdum(2)
        rrvn2o=rdum(3)
        rrvf11=rdum(4)
        rrvf12=rdum(5)
        rrvf113=rdum(6)
        rrvf22=rdum(7)
        return
      end if
      !--------------------------------------------------------------
      
      !--------------------------------------------------------------
      ! MJT read
      if (myid==0) then 
        read(lu,*) nlev
        write(6,*)'co2_read nlev=',nlev
c       Check that the number of levels is the same
        if ( nlev.ne.kl ) then
	    write(6,*) ' ERROR - Number of levels wrong in co2_data file'
	    stop
        end if
c       Check that the sigma levels are the same
c       Note that the radiation data has the levels in the reverse order
        read(lu,*) (sigin(i),i=kl,1,-1)
        write(6,*)'co2_read sigin=',sigin
        do k=1,kl
	    if ( abs(sigma(k)-sigin(k)) .gt. sigtol ) then
	      write(6,*) ' ERROR - sigma level wrong in co2_data file'
	      write(6,*) k, sigma(k), sigin(k)
	      stop
          end if
        end do
        read(lu,*) rrvco2
        write(6,*) ' CO2 mixing ratio is ', rrvco2*1e6,' ppmv'
        read(lu,*) stemp
        read(lu,*) gtemp
        read(lu,*) cdt51
        read(lu,*) co251
        read(lu,*) c2d51
        read(lu,*) cdt58
        read(lu,*) co258
        read(lu,*) c2d58
        read(lu,*) cdtm51
        read(lu,*) co2m51
        read(lu,*) c2dm51
        read(lu,*) cdtm58
        read(lu,*) co2m58
        read(lu,*) c2dm58
        read(lu,*) cdt31
        read(lu,*) co231
        read(lu,*) c2d31
        read(lu,*) cdt38
        read(lu,*) co238
        read(lu,*) c2d38
        read(lu,*) cdt71
        read(lu,*) co271
        read(lu,*) c2d71
        read(lu,*) cdt78
        read(lu,*) co278
        read(lu,*) c2d78
        read(lu,*) co211
        read(lu,*) co218
        close(lu)
      end if
      rdum(1)=rrvco2
      call ccmpi_bcast(rdum(1:1),0,comm_world)
      rrvco2=rdum(1)
      call ccmpi_bcast(stemp,0,comm_world)
      call ccmpi_bcast(gtemp,0,comm_world)
      call ccmpi_bcast(cdt51,0,comm_world)
      call ccmpi_bcast(co251,0,comm_world)
      call ccmpi_bcast(c2d51,0,comm_world)
      call ccmpi_bcast(cdt58,0,comm_world)
      call ccmpi_bcast(co258,0,comm_world)
      call ccmpi_bcast(c2d58,0,comm_world)
      call ccmpi_bcast(cdtm51,0,comm_world)
      call ccmpi_bcast(co2m51,0,comm_world)
      call ccmpi_bcast(c2dm51,0,comm_world)
      call ccmpi_bcast(cdtm58,0,comm_world)
      call ccmpi_bcast(co2m58,0,comm_world)
      call ccmpi_bcast(c2dm58,0,comm_world)
      call ccmpi_bcast(cdt31,0,comm_world)
      call ccmpi_bcast(co231,0,comm_world)
      call ccmpi_bcast(c2d31,0,comm_world)
      call ccmpi_bcast(cdt38,0,comm_world)
      call ccmpi_bcast(co238,0,comm_world)
      call ccmpi_bcast(c2d38,0,comm_world)
      call ccmpi_bcast(cdt71,0,comm_world)
      call ccmpi_bcast(co271,0,comm_world)
      call ccmpi_bcast(c2d71,0,comm_world)
      call ccmpi_bcast(cdt78,0,comm_world)
      call ccmpi_bcast(co278,0,comm_world)
      call ccmpi_bcast(c2d78,0,comm_world)
      call ccmpi_bcast(co211,0,comm_world)
      call ccmpi_bcast(co218,0,comm_world)
      !--------------------------------------------------------------
      
      return
      end
