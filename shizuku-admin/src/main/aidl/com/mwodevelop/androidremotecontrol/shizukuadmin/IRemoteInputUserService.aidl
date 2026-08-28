package com.mwodevelop.androidremotecontrol.shizukuadmin;

/** Narrow shell-UID input boundary used only by the reviewed remote-unlock flow. */
interface IRemoteInputUserService {
    boolean injectDigits(in byte[] digits) = 1;
    void destroy() = 16777114;
}
