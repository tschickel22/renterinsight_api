#!/bin/bash

# Phase 5A Setup Script
# This script creates all frontend and backend files for the unified login system

set -e  # Exit on any error

echo "=================================================="
echo "Phase 5A: Unified Login Setup"
echo "=================================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Paths
FRONTEND_PATH="/mnt/c/Users/tschi/src/Platform_DMS_8.4.25/Platform_DMS_8.4.25"
BACKEND_PATH="/home/tschi/src/renterinsight_api"

echo -e "${BLUE}Creating directories...${NC}"

# Create frontend directories
mkdir -p "$FRONTEND_PATH/src/services"
mkdir -p "$FRONTEND_PATH/src/hooks"
mkdir -p "$FRONTEND_PATH/src/pages/auth-login"

# Create backend directories
mkdir -p "$BACKEND_PATH/app/controllers/api/auth"

echo -e "${GREEN}✓ Directories created${NC}"
echo ""

#==================================================
# FRONTEND FILES
#==================================================

echo -e "${BLUE}Creating frontend files...${NC}"

# 1. authApi.ts
cat > "$FRONTEND_PATH/src/services/authApi.ts" << 'EOF'
import axios from 'axios';

// API Base URL - adjust based on your environment
const API_BASE_URL = process.env.REACT_APP_API_URL || 'http://localhost:5000/api';

// Create axios instance with default config
const authApiClient = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
  withCredentials: true, // Include cookies in requests
});

// Add token to requests if available
authApiClient.interceptors.request.use(
  (config) => {
    const token = localStorage.getItem('authToken');
    if (token) {
      config.headers.Authorization = `Bearer ${token}`;
    }
    return config;
  },
  (error) => {
    return Promise.reject(error);
  }
);

// Handle token refresh on 401 errors
authApiClient.interceptors.response.use(
  (response) => response,
  async (error) => {
    const originalRequest = error.config;

    // If 401 and not already retried, attempt token refresh
    if (error.response?.status === 401 && !originalRequest._retry) {
      originalRequest._retry = true;

      try {
        const refreshToken = localStorage.getItem('refreshToken');
        if (refreshToken) {
          const response = await axios.post(
            `${API_BASE_URL}/auth/refresh`,
            { refreshToken }
          );

          const { token } = response.data;
          localStorage.setItem('authToken', token);

          // Retry original request with new token
          originalRequest.headers.Authorization = `Bearer ${token}`;
          return authApiClient(originalRequest);
        }
      } catch (refreshError) {
        // Refresh failed, clear auth and redirect to login
        localStorage.removeItem('authToken');
        localStorage.removeItem('refreshToken');
        localStorage.removeItem('user');
        window.location.href = '/login';
        return Promise.reject(refreshError);
      }
    }

    return Promise.reject(error);
  }
);

// Types
export interface LoginCredentials {
  email: string;
  password: string;
}

export interface LoginResponse {
  success: boolean;
  token: string;
  refreshToken?: string;
  user: {
    id: string;
    email: string;
    firstName: string;
    lastName: string;
    user_type: 'admin' | 'client' | 'staff';
    role?: string;
    permissions?: string[];
  };
  message?: string;
}

export interface User {
  id: string;
  email: string;
  firstName: string;
  lastName: string;
  user_type: 'admin' | 'client' | 'staff';
  role?: string;
  permissions?: string[];
}

// Auth API Functions
const authApi = {
  /**
   * Login user with email and password
   */
  login: async (credentials: LoginCredentials): Promise<LoginResponse> => {
    try {
      const response = await authApiClient.post('/auth/login', credentials);
      
      const { token, refreshToken, user } = response.data;

      // Store authentication data
      if (token) {
        localStorage.setItem('authToken', token);
      }
      if (refreshToken) {
        localStorage.setItem('refreshToken', refreshToken);
      }
      if (user) {
        localStorage.setItem('user', JSON.stringify(user));
      }

      return response.data;
    } catch (error: any) {
      throw new Error(
        error.response?.data?.message || 
        error.message || 
        'Login failed. Please try again.'
      );
    }
  },

  /**
   * Logout current user
   */
  logout: async (): Promise<void> => {
    try {
      await authApiClient.post('/auth/logout');
    } catch (error) {
      console.error('Logout error:', error);
    } finally {
      // Always clear local storage
      localStorage.removeItem('authToken');
      localStorage.removeItem('refreshToken');
      localStorage.removeItem('user');
    }
  },

  /**
   * Refresh authentication token
   */
  refreshToken: async (): Promise<string> => {
    try {
      const refreshToken = localStorage.getItem('refreshToken');
      if (!refreshToken) {
        throw new Error('No refresh token available');
      }

      const response = await authApiClient.post('/auth/refresh', {
        refreshToken,
      });

      const { token } = response.data;
      localStorage.setItem('authToken', token);

      return token;
    } catch (error: any) {
      // Clear auth data on refresh failure
      localStorage.removeItem('authToken');
      localStorage.removeItem('refreshToken');
      localStorage.removeItem('user');
      throw new Error(error.response?.data?.message || 'Token refresh failed');
    }
  },

  /**
   * Get current authenticated user
   */
  getCurrentUser: (): User | null => {
    try {
      const userStr = localStorage.getItem('user');
      if (!userStr) return null;
      return JSON.parse(userStr);
    } catch (error) {
      console.error('Error parsing user data:', error);
      return null;
    }
  },

  /**
   * Check if user is authenticated
   */
  isAuthenticated: (): boolean => {
    const token = localStorage.getItem('authToken');
    const user = authApi.getCurrentUser();
    return !!(token && user);
  },

  /**
   * Get authentication token
   */
  getToken: (): string | null => {
    return localStorage.getItem('authToken');
  },

  /**
   * Verify token is still valid
   */
  verifyToken: async (): Promise<boolean> => {
    try {
      const response = await authApiClient.get('/auth/verify');
      return response.data.valid === true;
    } catch (error) {
      return false;
    }
  },

  /**
   * Request password reset
   */
  requestPasswordReset: async (email: string): Promise<void> => {
    try {
      await authApiClient.post('/auth/forgot-password', { email });
    } catch (error: any) {
      throw new Error(
        error.response?.data?.message || 
        'Failed to send password reset email'
      );
    }
  },

  /**
   * Reset password with token
   */
  resetPassword: async (token: string, newPassword: string): Promise<void> => {
    try {
      await authApiClient.post('/auth/reset-password', {
        token,
        newPassword,
      });
    } catch (error: any) {
      throw new Error(
        error.response?.data?.message || 
        'Failed to reset password'
      );
    }
  },
};

export default authApi;
EOF

echo -e "${GREEN}✓ Created authApi.ts${NC}"

# 2. useAuthLogin.ts
cat > "$FRONTEND_PATH/src/hooks/useAuthLogin.ts" << 'EOF'
import { useState, FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import authApi, { LoginCredentials } from '../services/authApi';

interface UseAuthLoginOptions {
  redirectPath?: string;
  onSuccess?: () => void;
  onError?: (error: string) => void;
}

interface UseAuthLoginReturn {
  email: string;
  password: string;
  isLoading: boolean;
  error: string | null;
  setEmail: (email: string) => void;
  setPassword: (password: string) => void;
  handleSubmit: (e: FormEvent<HTMLFormElement>) => Promise<void>;
  clearError: () => void;
}

export const useAuthLogin = (options: UseAuthLoginOptions = {}): UseAuthLoginReturn => {
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const validateForm = (): string | null => {
    if (!email.trim()) {
      return 'Email is required';
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return 'Please enter a valid email address';
    }

    if (!password) {
      return 'Password is required';
    }

    if (password.length < 6) {
      return 'Password must be at least 6 characters';
    }

    return null;
  };

  const getRedirectPath = (userType: string): string => {
    if (options.redirectPath) {
      return options.redirectPath;
    }

    switch (userType) {
      case 'admin':
        return '/admin/dashboard';
      case 'client':
        return '/client/dashboard';
      case 'staff':
        return '/staff/dashboard';
      default:
        return '/dashboard';
    }
  };

  const handleSubmit = async (e: FormEvent<HTMLFormElement>): Promise<void> => {
    e.preventDefault();
    setError(null);

    const validationError = validateForm();
    if (validationError) {
      setError(validationError);
      if (options.onError) {
        options.onError(validationError);
      }
      return;
    }

    setIsLoading(true);

    try {
      const credentials: LoginCredentials = {
        email: email.trim(),
        password,
      };

      const response = await authApi.login(credentials);

      if (response.success && response.user) {
        if (options.onSuccess) {
          options.onSuccess();
        }

        const redirectPath = getRedirectPath(response.user.user_type);

        setTimeout(() => {
          navigate(redirectPath, { replace: true });
        }, 100);
      } else {
        throw new Error(response.message || 'Login failed');
      }
    } catch (err: any) {
      const errorMessage = err.message || 'An error occurred during login. Please try again.';
      setError(errorMessage);

      if (options.onError) {
        options.onError(errorMessage);
      }

      console.error('Login error:', err);
    } finally {
      setIsLoading(false);
    }
  };

  const clearError = () => {
    setError(null);
  };

  return {
    email,
    password,
    isLoading,
    error,
    setEmail,
    setPassword,
    handleSubmit,
    clearError,
  };
};

export default useAuthLogin;
EOF

echo -e "${GREEN}✓ Created useAuthLogin.ts${NC}"

# 3. UnifiedLogin.tsx
cat > "$FRONTEND_PATH/src/pages/auth-login/UnifiedLogin.tsx" << 'EOF'
import React from 'react';
import { Link } from 'react-router-dom';
import { useAuthLogin } from '../../hooks/useAuthLogin';

const UnifiedLogin: React.FC = () => {
  const {
    email,
    password,
    isLoading,
    error,
    setEmail,
    setPassword,
    handleSubmit,
    clearError,
  } = useAuthLogin();

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-gray-50 to-gray-100 py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-md w-full space-y-8">
        <div className="text-center">
          <div className="mx-auto h-16 w-16 flex items-center justify-center rounded-full bg-blue-600">
            <svg className="h-10 w-10 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
            </svg>
          </div>
          <h2 className="mt-6 text-3xl font-extrabold text-gray-900">Sign in to your account</h2>
          <p className="mt-2 text-sm text-gray-600">Welcome back! Please enter your credentials to continue.</p>
        </div>

        <form className="mt-8 space-y-6" onSubmit={handleSubmit}>
          {error && (
            <div className="rounded-md bg-red-50 p-4">
              <div className="flex">
                <div className="flex-shrink-0">
                  <svg className="h-5 w-5 text-red-400" fill="currentColor" viewBox="0 0 20 20">
                    <path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clipRule="evenodd" />
                  </svg>
                </div>
                <div className="ml-3 flex-1">
                  <p className="text-sm font-medium text-red-800">{error}</p>
                </div>
                <div className="ml-auto pl-3">
                  <button type="button" onClick={clearError} className="inline-flex rounded-md bg-red-50 p-1.5 text-red-500 hover:bg-red-100">
                    <span className="sr-only">Dismiss</span>
                    <svg className="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                      <path fillRule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clipRule="evenodd" />
                    </svg>
                  </button>
                </div>
              </div>
            </div>
          )}

          <div className="rounded-md shadow-sm -space-y-px">
            <div>
              <label htmlFor="email" className="sr-only">Email address</label>
              <input id="email" name="email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} className="appearance-none rounded-none relative block w-full px-3 py-3 border border-gray-300 placeholder-gray-500 text-gray-900 rounded-t-md focus:outline-none focus:ring-blue-500 focus:border-blue-500 focus:z-10 sm:text-sm" placeholder="Email address" disabled={isLoading} />
            </div>
            <div>
              <label htmlFor="password" className="sr-only">Password</label>
              <input id="password" name="password" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} className="appearance-none rounded-none relative block w-full px-3 py-3 border border-gray-300 placeholder-gray-500 text-gray-900 rounded-b-md focus:outline-none focus:ring-blue-500 focus:border-blue-500 focus:z-10 sm:text-sm" placeholder="Password" disabled={isLoading} />
            </div>
          </div>

          <div className="flex items-center justify-between">
            <div className="flex items-center">
              <input id="remember-me" name="remember-me" type="checkbox" className="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded" />
              <label htmlFor="remember-me" className="ml-2 block text-sm text-gray-900">Remember me</label>
            </div>
            <div className="text-sm">
              <Link to="/forgot-password" className="font-medium text-blue-600 hover:text-blue-500">Forgot your password?</Link>
            </div>
          </div>

          <div>
            <button type="submit" disabled={isLoading} className="group relative w-full flex justify-center py-3 px-4 border border-transparent text-sm font-medium rounded-md text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed transition-colors duration-200">
              {isLoading ? (
                <>
                  <svg className="animate-spin -ml-1 mr-3 h-5 w-5 text-white" fill="none" viewBox="0 0 24 24">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
                  </svg>
                  Signing in...
                </>
              ) : (
                'Sign in'
              )}
            </button>
          </div>
        </form>

        <div className="text-center space-y-2">
          <p className="text-sm text-gray-600">
            Don't have an account? <Link to="/register" className="font-medium text-blue-600 hover:text-blue-500">Sign up</Link>
          </p>
          <div className="flex items-center justify-center space-x-4 text-xs text-gray-500">
            <Link to="/admin/login" className="hover:text-gray-700">Admin Login</Link>
            <span>•</span>
            <Link to="/client/login" className="hover:text-gray-700">Client Portal</Link>
          </div>
        </div>
      </div>
    </div>
  );
};

export default UnifiedLogin;
EOF

echo -e "${GREEN}✓ Created UnifiedLogin.tsx${NC}"

# 4. AdminLogin.tsx
cat > "$FRONTEND_PATH/src/pages/auth-login/AdminLogin.tsx" << 'EOF'
import React from 'react';
import { Link } from 'react-router-dom';
import { useAuthLogin } from '../../hooks/useAuthLogin';

const AdminLogin: React.FC = () => {
  const {
    email,
    password,
    isLoading,
    error,
    setEmail,
    setPassword,
    handleSubmit,
    clearError,
  } = useAuthLogin();

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-md w-full space-y-8">
        <div className="text-center">
          <div className="mx-auto h-20 w-20 flex items-center justify-center rounded-full bg-gradient-to-br from-indigo-600 to-purple-600 shadow-xl">
            <svg className="h-12 w-12 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
            </svg>
          </div>
          <h2 className="mt-6 text-3xl font-extrabold text-white">Admin Portal</h2>
          <p className="mt-2 text-sm text-gray-300">Authorized personnel only</p>
        </div>

        <div className="bg-white rounded-lg shadow-2xl p-8">
          <form className="space-y-6" onSubmit={handleSubmit}>
            {error && (
              <div className="rounded-md bg-red-50 p-4">
                <div className="flex">
                  <div className="flex-shrink-0">
                    <svg className="h-5 w-5 text-red-400" fill="currentColor" viewBox="0 0 20 20">
                      <path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clipRule="evenodd" />
                    </svg>
                  </div>
                  <div className="ml-3 flex-1">
                    <p className="text-sm font-medium text-red-800">{error}</p>
                  </div>
                  <div className="ml-auto pl-3">
                    <button type="button" onClick={clearError} className="inline-flex rounded-md bg-red-50 p-1.5 text-red-500 hover:bg-red-100">
                      <span className="sr-only">Dismiss</span>
                      <svg className="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                        <path fillRule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clipRule="evenodd" />
                      </svg>
                    </button>
                  </div>
                </div>
              </div>
            )}

            <div>
              <label htmlFor="admin-email" className="block text-sm font-medium text-gray-700 mb-2">Admin Email</label>
              <input id="admin-email" name="email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} className="appearance-none block w-full px-4 py-3 border border-gray-300 rounded-md shadow-sm placeholder-gray-400 focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm" placeholder="admin@company.com" disabled={isLoading} />
            </div>

            <div>
              <label htmlFor="admin-password" className="block text-sm font-medium text-gray-700 mb-2">Password</label>
              <input id="admin-password" name="password" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} className="appearance-none block w-full px-4 py-3 border border-gray-300 rounded-md shadow-sm placeholder-gray-400 focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm" placeholder="••••••••" disabled={isLoading} />
            </div>

            <div className="flex items-center justify-between">
              <div className="flex items-center">
                <input id="admin-remember-me" name="remember-me" type="checkbox" className="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded" />
                <label htmlFor="admin-remember-me" className="ml-2 block text-sm text-gray-700">Remember me</label>
              </div>
              <div className="text-sm">
                <Link to="/admin/forgot-password" className="font-medium text-indigo-600 hover:text-indigo-500">Forgot password?</Link>
              </div>
            </div>

            <div>
              <button type="submit" disabled={isLoading} className="w-full flex justify-center py-3 px-4 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-gradient-to-r from-indigo-600 to-purple-600 hover:from-indigo-700 hover:to-purple-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all duration-200">
                {isLoading ? (
                  <>
                    <svg className="animate-spin -ml-1 mr-3 h-5 w-5 text-white" fill="none" viewBox="0 0 24 24">
                      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
                    </svg>
                    Authenticating...
                  </>
                ) : (
                  <>
                    <svg className="h-5 w-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
                    </svg>
                    Sign in to Admin Portal
                  </>
                )}
              </button>
            </div>
          </form>

          <div className="mt-6 pt-6 border-t border-gray-200">
            <div className="flex items-start">
              <svg className="h-5 w-5 text-gray-400 mt-0.5" fill="currentColor" viewBox="0 0 20 20">
                <path fillRule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clipRule="evenodd" />
              </svg>
              <p className="ml-3 text-xs text-gray-500">This is a secure admin area. All login attempts are monitored and logged. Unauthorized access is prohibited.</p>
            </div>
          </div>
        </div>

        <div className="text-center">
          <Link to="/login" className="text-sm font-medium text-gray-300 hover:text-white transition-colors">← Back to general login</Link>
        </div>
      </div>
    </div>
  );
};

export default AdminLogin;
EOF

echo -e "${GREEN}✓ Created AdminLogin.tsx${NC}"

# 5. ClientPortalLogin.tsx
cat > "$FRONTEND_PATH/src/pages/auth-login/ClientPortalLogin.tsx" << 'EOF'
import React from 'react';
import { Link } from 'react-router-dom';
import { useAuthLogin } from '../../hooks/useAuthLogin';

const ClientPortalLogin: React.FC = () => {
  const {
    email,
    password,
    isLoading,
    error,
    setEmail,
    setPassword,
    handleSubmit,
    clearError,
  } = useAuthLogin();

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-blue-50 via-indigo-50 to-purple-50 py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-md w-full space-y-8">
        <div className="text-center">
          <div className="mx-auto h-20 w-20 flex items-center justify-center rounded-full bg-gradient-to-br from-blue-500 to-indigo-600 shadow-lg">
            <svg className="h-11 w-11 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z" />
            </svg>
          </div>
          <h2 className="mt-6 text-3xl font-bold text-gray-900">Welcome to Client Portal</h2>
          <p className="mt-2 text-sm text-gray-600">Access your account and manage your services</p>
        </div>

        <div className="bg-white rounded-2xl shadow-xl p-8 border border-gray-100">
          <form className="space-y-6" onSubmit={handleSubmit}>
            {error && (
              <div className="rounded-lg bg-red-50 p-4 border border-red-100">
                <div className="flex">
                  <div className="flex-shrink-0">
                    <svg className="h-5 w-5 text-red-400" fill="currentColor" viewBox="0 0 20 20">
                      <path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clipRule="evenodd" />
                    </svg>
                  </div>
                  <div className="ml-3 flex-1">
                    <p className="text-sm font-medium text-red-800">{error}</p>
                  </div>
                  <div className="ml-auto pl-3">
                    <button type="button" onClick={clearError} className="inline-flex rounded-md bg-red-50 p-1.5 text-red-500 hover:bg-red-100">
                      <span className="sr-only">Dismiss</span>
                      <svg className="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                        <path fillRule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clipRule="evenodd" />
                      </svg>
                    </button>
                  </div>
                </div>
              </div>
            )}

            <div>
              <label htmlFor="client-email" className="block text-sm font-medium text-gray-700 mb-2">Email Address</label>
              <div className="relative">
                <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                  <svg className="h-5 w-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M16 12a4 4 0 10-8 0 4 4 0 008 0zm0 0v1.5a2.5 2.5 0 005 0V12a9 9 0 10-9 9m4.5-1.206a8.959 8.959 0 01-4.5 1.207" />
                  </svg>
                </div>
                <input id="client-email" name="email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} className="appearance-none block w-full pl-10 pr-4 py-3 border border-gray-300 rounded-lg shadow-sm placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent sm:text-sm transition-colors" placeholder="you@example.com" disabled={isLoading} />
              </div>
            </div>

            <div>
              <label htmlFor="client-password" className="block text-sm font-medium text-gray-700 mb-2">Password</label>
              <div className="relative">
                <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                  <svg className="h-5 w-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
                  </svg>
                </div>
                <input id="client-password" name="password" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} className="appearance-none block w-full pl-10 pr-4 py-3 border border-gray-300 rounded-lg shadow-sm placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent sm:text-sm transition-colors" placeholder="••••••••" disabled={isLoading} />
              </div>
            </div>

            <div className="flex items-center justify-between">
              <div className="flex items-center">
                <input id="client-remember-me" name="remember-me" type="checkbox" className="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded" />
                <label htmlFor="client-remember-me" className="ml-2 block text-sm text-gray-700">Keep me signed in</label>
              </div>
              <div className="text-sm">
                <Link to="/client/forgot-password" className="font-medium text-blue-600 hover:text-blue-500 transition-colors">Forgot password?</Link>
              </div>
            </div>

            <div>
              <button type="submit" disabled={isLoading} className="w-full flex justify-center items-center py-3 px-4 border border-transparent rounded-lg shadow-sm text-sm font-medium text-white bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-700 hover:to-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all duration-200 transform hover:scale-[1.02]">
                {isLoading ? (
                  <>
                    <svg className="animate-spin -ml-1 mr-3 h-5 w-5 text-white" fill="none" viewBox="0 0 24 24">
                      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
                    </svg>
                    Signing in...
                  </>
                ) : (
                  <>
                    <svg className="h-5 w-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M11 16l-4-4m0 0l4-4m-4 4h14m-5 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h7a3 3 0 013 3v1" />
                    </svg>
                    Access Your Portal
                  </>
                )}
              </button>
            </div>
          </form>

          <div className="mt-6 pt-6 border-t border-gray-200">
            <div className="flex items-center justify-center space-x-2 text-sm text-gray-600">
              <svg className="h-5 w-5 text-blue-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <span>Need help?</span>
              <Link to="/support" className="font-medium text-blue-600 hover:text-blue-500">Contact Support</Link>
            </div>
          </div>
        </div>

        <div className="text-center space-y-3">
          <p className="text-sm text-gray-600">
            New client? <Link to="/client/register" className="font-medium text-blue-600 hover:text-blue-500">Create an account</Link>
          </p>
          <Link to="/login" className="inline-flex items-center text-sm font-medium text-gray-500 hover:text-gray-700 transition-colors">
            <svg className="h-4 w-4 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 19l-7-7m0 0l7-7m-7 7h18" />
            </svg>
            Back to main login
          </Link>
        </div>
      </div>
    </div>
  );
};

export default ClientPortalLogin;
EOF

echo -e "${GREEN}✓ Created ClientPortalLogin.tsx${NC}"

# 6. index.ts
cat > "$FRONTEND_PATH/src/pages/auth-login/index.ts" << 'EOF'
export { default as UnifiedLogin } from './UnifiedLogin';
export { default as AdminLogin } from './AdminLogin';
export { default as ClientPortalLogin } from './ClientPortalLogin';
EOF

echo -e "${GREEN}✓ Created index.ts${NC}"

#==================================================
# BACKEND FILES
#==================================================

echo ""
echo -e "${BLUE}Creating backend files...${NC}"

# Backend controller
cat > "$BACKEND_PATH/app/controllers/api/auth/login_controller.rb" << 'EOF'
# frozen_string_literal: true

module Api
  module Auth
    class LoginController < ApplicationController
      skip_before_action :verify_authenticity_token
      skip_before_action :authenticate_user!

      # POST /api/auth/login
      def create
        user = User.find_by(email: params[:email]&.downcase)

        if user&.valid_password?(params[:password])
          if user.inactive? || user.suspended?
            render json: {
              success: false,
              message: 'Your account has been deactivated. Please contact support.'
            }, status: :forbidden
            return
          end

          access_token = generate_access_token(user)
          refresh_token = generate_refresh_token(user)

          user.update(last_sign_in_at: Time.current)

          set_refresh_token_cookie(refresh_token)

          render json: {
            success: true,
            message: 'Login successful',
            token: access_token,
            refreshToken: refresh_token,
            user: {
              id: user.id,
              email: user.email,
              firstName: user.first_name,
              lastName: user.last_name,
              user_type: determine_user_type(user),
              role: user.role,
              permissions: user.permissions || []
            }
          }, status: :ok
        else
          render json: {
            success: false,
            message: 'Invalid email or password'
          }, status: :unauthorized
        end
      rescue StandardError => e
        Rails.logger.error("Login error: #{e.message}")
        render json: {
          success: false,
          message: 'An error occurred during login. Please try again.'
        }, status: :internal_server_error
      end

      # POST /api/auth/logout
      def destroy
        cookies.delete(:refresh_token, domain: :all, secure: Rails.env.production?)

        render json: {
          success: true,
          message: 'Logout successful'
        }, status: :ok
      rescue StandardError => e
        Rails.logger.error("Logout error: #{e.message}")
        render json: {
          success: false,
          message: 'An error occurred during logout'
        }, status: :internal_server_error
      end

      # POST /api/auth/refresh
      def refresh
        refresh_token = cookies[:refresh_token] || params[:refreshToken]

        if refresh_token.blank?
          render json: {
            success: false,
            message: 'Refresh token is required'
          }, status: :unauthorized
          return
        end

        begin
          decoded = JWT.decode(
            refresh_token,
            Rails.application.credentials.jwt_refresh_secret || ENV['JWT_REFRESH_SECRET'],
            true,
            { algorithm: 'HS256' }
          )[0]

          user = User.find(decoded['user_id'])

          if user.inactive? || user.suspended?
            render json: {
              success: false,
              message: 'Account is not active'
            }, status: :forbidden
            return
          end

          new_access_token = generate_access_token(user)

          render json: {
            success: true,
            token: new_access_token
          }, status: :ok
        rescue JWT::DecodeError => e
          render json: {
            success: false,
            message: 'Invalid or expired refresh token'
          }, status: :unauthorized
        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            message: 'User not found'
          }, status: :unauthorized
        end
      end

      # GET /api/auth/verify
      def verify
        render json: {
          success: true,
          valid: true,
          user: {
            id: current_user.id,
            email: current_user.email,
            firstName: current_user.first_name,
            lastName: current_user.last_name,
            user_type: determine_user_type(current_user),
            role: current_user.role
          }
        }, status: :ok
      end

      # GET /api/auth/me
      def me
        render json: {
          success: true,
          user: {
            id: current_user.id,
            email: current_user.email,
            firstName: current_user.first_name,
            lastName: current_user.last_name,
            user_type: determine_user_type(current_user),
            role: current_user.role,
            permissions: current_user.permissions || []
          }
        }, status: :ok
      end

      private

      def generate_access_token(user)
        payload = {
          user_id: user.id,
          email: user.email,
          user_type: determine_user_type(user),
          role: user.role,
          exp: 24.hours.from_now.to_i
        }

        JWT.encode(
          payload,
          Rails.application.credentials.jwt_secret || ENV['JWT_SECRET'],
          'HS256'
        )
      end

      def generate_refresh_token(user)
        payload = {
          user_id: user.id,
          email: user.email,
          exp: 7.days.from_now.to_i
        }

        JWT.encode(
          payload,
          Rails.application.credentials.jwt_refresh_secret || ENV['JWT_REFRESH_SECRET'],
          'HS256'
        )
      end

      def set_refresh_token_cookie(token)
        cookies[:refresh_token] = {
          value: token,
          httponly: true,
          secure: Rails.env.production?,
          same_site: :strict,
          expires: 7.days.from_now
        }
      end

      def determine_user_type(user)
        return 'admin' if user.respond_to?(:admin?) && user.admin?
        return 'admin' if user.role == 'admin' || user.role == 'super_admin'
        return 'client' if user.respond_to?(:client?) && user.client?
        return 'client' if user.role == 'client' || user.role == 'buyer'
        return 'staff' if user.respond_to?(:staff?) && user.staff?
        return 'staff' if user.role == 'staff' || user.role == 'employee'

        'staff'
      end
    end
  end
end
EOF

echo -e "${GREEN}✓ Created login_controller.rb${NC}"

echo ""
echo -e "${GREEN}=================================================="
echo "✅ Phase 5A Setup Complete!"
echo "==================================================${NC}"
echo ""
echo -e "${YELLOW}📋 Next Steps:${NC}"
echo ""
echo "1. Install frontend dependencies:"
echo "   cd $FRONTEND_PATH"
echo "   npm install axios"
echo ""
echo "2. Add backend routes to config/routes.rb:"
echo "   namespace :api do"
echo "     namespace :auth do"
echo "       post 'login', to: 'login#create'"
echo "       post 'logout', to: 'login#destroy'"
echo "       post 'refresh', to: 'login#refresh'"
echo "       get 'verify', to: 'login#verify'"
echo "       get 'me', to: 'login#me'"
echo "     end"
echo "   end"
echo ""
echo "3. Set environment variables:"
echo "   Frontend .env: REACT_APP_API_URL=http://localhost:5000/api"
echo "   Backend .env:"
echo "     JWT_SECRET=your-secret-key"
echo "     JWT_REFRESH_SECRET=your-refresh-key"
echo ""
echo "4. Update App.tsx to add routes (see PHASE_5A_ROUTE_INTEGRATION.md)"
echo ""
echo -e "${GREEN}📂 Files Created:${NC}"
echo "  Frontend:"
echo "    ✓ src/services/authApi.ts"
echo "    ✓ src/hooks/useAuthLogin.ts"
echo "    ✓ src/pages/auth-login/UnifiedLogin.tsx"
echo "    ✓ src/pages/auth-login/AdminLogin.tsx"
echo "    ✓ src/pages/auth-login/ClientPortalLogin.tsx"
echo "    ✓ src/pages/auth-login/index.ts"
echo "  Backend:"
echo "    ✓ app/controllers/api/auth/login_controller.rb"
echo ""
echo -e "${BLUE}📖 Documentation: See PHASE_5A_QUICK_START.md${NC}"
echo ""
echo "Done! 🎉"
EOF

chmod +x "$BACKEND_PATH/setup_phase5a.sh"

echo -e "${GREEN}✅ Setup script created!${NC}"
echo ""
echo "Run this command to execute the script:"
echo ""
echo -e "${BLUE}cd ~/src/renterinsight_api && ./setup_phase5a.sh${NC}"
