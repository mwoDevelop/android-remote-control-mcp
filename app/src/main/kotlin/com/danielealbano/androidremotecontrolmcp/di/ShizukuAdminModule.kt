package com.danielealbano.androidremotecontrolmcp.di

import android.content.Context
import com.danielealbano.androidremotecontrolmcp.mcp.shizuku.AndroidProtectedPackagePolicy
import com.danielealbano.androidremotecontrolmcp.mcp.shizuku.ProtectedPackagePolicy
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackend
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackendFactory
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/** Hilt binding for the isolated, application-owned Shizuku boundary. */
@Module
@InstallIn(SingletonComponent::class)
object ShizukuAdminModule {
    @Provides
    @Singleton
    fun providePrivilegedAdminBackend(
        @ApplicationContext context: Context,
    ): PrivilegedAdminBackend = PrivilegedAdminBackendFactory.create(context)
}

/** Interface binding kept separate because Dagger forbids mixing abstract binds with object providers. */
@Module
@InstallIn(SingletonComponent::class)
abstract class ShizukuAdminPolicyModule {
    @Binds
    @Singleton
    abstract fun bindProtectedPackagePolicy(implementation: AndroidProtectedPackagePolicy): ProtectedPackagePolicy
}
