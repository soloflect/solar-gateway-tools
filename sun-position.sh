#!/bin/bash
################################################################################
# sun-position.sh
#
# Calculate the Sun's azimuth, elevation, sunrise, and sunset.
#
# Usage:
#   sun-position.sh LAT LON "UTC"
#
# Example:
#   sun-position.sh 44.11588 -72.6866 "2026-08-25 14:00:00"
#
# Output:
#   AZ=angle EL=angle SUNRISE=UTC SUNSET=UTC
#
# Copyright (C) 2025
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
################################################################################
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 LAT LON \"YYYY-MM-DD HH:MM:SS\"" >&2
    exit 1
fi

lat="$1"
lon="$2"
utc="$3"

awk -v lat="$lat" -v lon="$lon" -v utc="$utc" '
function rad(x)    { return x * pi / 180 }
function deg(x)    { return x * 180 / pi }
function tan(x)    { return sin(x) / cos(x) }
function asin(x)   {
    if (x > 1) x=1
    if (x < -1) x=-1
    return atan2(x, sqrt(1-x*x))
}
function acos(x)   {
    if (x > 1) x=1
    if (x < -1) x=-1
    return atan2(sqrt(1-x*x), x)
}
function mod(x,y)  { return x-y*int(x/y) }
function norm360(x) {
    x=mod(x,360)
    return x < 0 ? x+360 : x
}
function fmt_time(minutes, h,m,s) {
    while (minutes < 0)    minutes += 1440
    while (minutes >= 1440) minutes -= 1440

    h=int(minutes/60)
    m=int(minutes-h*60)
    s=int((minutes-h*60-m)*60+0.5)

    if (s >= 60) { s=0; m++ }
    if (m >= 60) { m=0; h++ }
    if (h >= 24) h=0

    return sprintf("%02d:%02d:%02d",h,m,s)
}

BEGIN {
    pi=3.14159265358979323846

    # Parse UTC timestamp.
    split(utc,d,/[- :]/)

    year=d[1]
    month=d[2]
    day=d[3]
    hour=d[4]
    minute=d[5]
    second=d[6]

    # Julian Day.
    if (month <= 2) {
        yy=year-1
        mm=month+12
    } else {
        yy=year
        mm=month
    }

    A=int(yy/100)
    B=2-A+int(A/4)

    JD=int(365.25*(yy+4716)) \
       +int(30.6001*(mm+1)) \
       +day+B-1524.5

    JD += (hour+minute/60+second/3600)/24

    # Julian centuries from J2000.0.
    T=(JD-2451545.0)/36525

    # Solar coordinates.
    L0=norm360(280.46646+T*(36000.76983+T*0.0003032))
    M=357.52911+T*(35999.05029-0.0001537*T)
    e=0.016708634-T*(0.000042037+0.0000001267*T)

    C=sin(rad(M))*(1.914602-T*(0.004817+0.000014*T)) \
     +sin(rad(2*M))*(0.019993-0.000101*T) \
     +sin(rad(3*M))*0.000289

    true_long=L0+C

    omega=125.04-1934.136*T

    lambda=true_long \
           -0.00569 \
           -0.00478*sin(rad(omega))

    eps0=23+(26+(21.448 \
        -T*(46.815+T*(0.00059-T*0.001813)))/60)/60

    eps=eps0+0.00256*cos(rad(omega))

    # Solar declination.
    decl=deg(asin(sin(rad(eps))*sin(rad(lambda))))

    # Equation of time, minutes.
    y=tan(rad(eps/2))
    y=y*y

    L0r=rad(L0)
    Mr=rad(M)

    Etime=4*deg( \
          y*sin(2*L0r) \
        - 2*e*sin(Mr) \
        + 4*e*y*sin(Mr)*cos(2*L0r) \
        - 0.5*y*y*sin(4*L0r) \
        - 1.25*e*e*sin(2*Mr) \
        )

    # True solar time.
    utc_minutes=hour*60+minute+second/60

    tst=utc_minutes+Etime+4*lon

    while (tst < 0)    tst+=1440
    while (tst >= 1440) tst-=1440

    # Solar hour angle.
    hour_angle=tst/4-180

    if (hour_angle < -180)
        hour_angle+=360

    latr=rad(lat)
    declr=rad(decl)
    har=rad(hour_angle)

    # Solar zenith.
    cosz=sin(latr)*sin(declr) \
        +cos(latr)*cos(declr)*cos(har)

    if (cosz > 1)  cosz=1
    if (cosz < -1) cosz=-1

    zenith=deg(acos(cosz))
    elevation=90-zenith

    # Azimuth, clockwise from North.
    azimuth=norm360( \
        deg(atan2( \
            sin(har), \
            cos(har)*sin(latr)-tan(declr)*cos(latr) \
        ))+180 \
    )

    # Sunrise/sunset.
    #
    # 90.833 degrees accounts for the apparent solar disk
    # and atmospheric refraction at the horizon.
    zenith0=90.833

    cosH=(cos(rad(zenith0))/(cos(latr)*cos(declr))) \
        -tan(latr)*tan(declr)

    if (cosH > 1 || cosH < -1) {
        sunrise="NONE"
        sunset="NONE"
    } else {
        H=deg(acos(cosH))

        sunrise_min=720-4*(lon+H)-Etime
        sunset_min=720-4*(lon-H)-Etime

        sunrise=fmt_time(sunrise_min)
        sunset=fmt_time(sunset_min)
    }

    printf "AZ=%.2f EL=%.2f SUNRISE=%s SUNSET=%s\n", \
           azimuth,elevation,sunrise,sunset
}'

